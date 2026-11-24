.pragma library

// MyŠkoda Public API (developer docs: https://public.api.connect.skoda-auto.cz/docs).
// Rate limit: 20 requests per hour per VIN, so every fetch is one request and failures back off.
var API_HOST = "https://public.api.connect.skoda-auto.cz"

// base overrides the host so tests can point at a mock server.
function vehicleUrl(base, vin) {
    return (base || API_HOST).replace(/\/$/, "") + "/api/v1/vehicles/" + encodeURIComponent(vin)
}

// Qt's date parser is stricter than node's: the API sends one to nine fractional digits, so they are made exactly three.
function ts(s) {
    var t = Date.parse(String(s || "").replace(/\.(\d+)/, function (_, f) { return "." + (f + "000").slice(0, 3) }))
    return isNaN(t) ? 0 : t
}

function section(v, key) {
    return v[key] && typeof v[key] === "object" ? v[key] : {}
}

// Plug and charge process as one word: charging, interrupted, plugged, unplugged or unknown.
// The API omits the derived state in everyday situations, so the plug state decides when it is missing.
function chargeStatus(cs) {
    var state = cs.state
    var plug = cs.plugConnectionState
    if (state === "CHARGING")
        return "charging"
    if (state === "CHARGING_INTERRUPTED")
        return "interrupted"
    if (plug === "CONNECTED" || state === "READY_FOR_CHARGING" || state === "CONSERVING")
        return "plugged"
    if (plug === "DISCONNECTED" || state === "CONNECT_CABLE")
        return "unplugged"
    return "unknown"
}

var AC_ON = ["COOLING", "HEATING", "HEATING_AUXILIARY", "VENTILATION"]

function lockState(overall) {
    var s = overall.reliableLockStatus || overall.locked
    return s === "LOCKED" || s === "YES" ? "locked" : s === "UNLOCKED" || s === "NO" ? "unlocked" : "unknown"
}

// Turns the vehicle response into a flat model, or { error } with a kind for the caller to translate.
function parse(body) {
    var json
    try {
        json = typeof body === "string" ? JSON.parse(body) : body
    } catch (e) {
        return { error: "badresponse" }
    }
    var v = json && json.vehicle
    if (!v)
        return { error: "badresponse" }

    var charging = section(v, "charging")
    var cs = section(charging, "status")
    var settings = section(charging, "settings")
    var battery = section(cs, "battery")
    var status = section(v, "status")
    var overall = section(status, "overall")
    var detail = section(status, "detail")
    var ac = section(v, "airConditioning")
    var temp = section(ac, "targetTemperature")
    var odometer = section(v, "odometer")
    if (!v.charging && !v.odometer && !v.status && !v.airConditioning)
        return { error: "nodata" }

    var open = []
    if (overall.doors === "OPEN")
        open.push("doors")
    if (overall.windows === "OPEN")
        open.push("windows")
    if (detail.trunk === "OPEN")
        open.push("trunk")
    if (detail.bonnet === "OPEN")
        open.push("bonnet")

    var stamps = [charging, status, ac, odometer].map(function (s) { return ts(s.carCapturedTimestamp) })
    var ops = (v.operations || []).map(function (o) { return o.name })
    var status2 = chargeStatus(cs)
    var errors = (json.errors || []).map(function (e) { return e.type })

    return {
        vin: v.vin,
        name: v.name || "Škoda",
        soc: battery.stateOfChargeInPercent === undefined ? null : battery.stateOfChargeInPercent,
        rangeKm: battery.remainingCruisingRangeInMeters === undefined ? null : Math.round(battery.remainingCruisingRangeInMeters / 1000),
        target: settings.targetStateOfChargeInPercent === undefined ? null : settings.targetStateOfChargeInPercent,
        status: status2,
        charging: status2 === "charging",
        powerKw: cs.chargePowerInKw === undefined ? null : cs.chargePowerInKw,
        minutesLeft: cs.remainingTimeToFullyChargedInMinutes === undefined ? null : cs.remainingTimeToFullyChargedInMinutes,
        fullAt: ts(cs.fullyChargedAt),
        chargeType: cs.chargeType || "",
        plugLocked: cs.plugLockState === "LOCKED",
        odometerKm: odometer.mileageInKm === undefined ? null : odometer.mileageInKm,
        lock: lockState(overall),
        hasStatus: !!v.status,
        open: open,
        closed: overall.doors === "CLOSED" && overall.windows === "CLOSED" && open.length === 0,
        ac: {
            state: ac.state || "",
            on: AC_ON.indexOf(ac.state) >= 0,
            targetTemp: temp.value,
            unit: temp.unit || "CELSIUS",
            reachAt: ts(ac.estimatedReachOfTargetTemperatureAt),
            withoutPower: ac.airConditioningWithoutExternalPower
        },
        canStartAc: ops.indexOf("startAirConditioning") >= 0,
        canStopAc: ops.indexOf("stopAirConditioning") >= 0,
        seenAt: ts(charging.carCapturedTimestamp) || Math.max.apply(null, stamps),
        errors: errors,
        // RENDER_UNAVAILABLE is about the car picture, which is not used.
        partial: errors.filter(function (e) { return e !== "RENDER_UNAVAILABLE" }).length > 0
    }
}

// The air conditioning request: the car's own target temperature, and external power is not demanded
// unless the car says so, because starting it while unplugged is the usual reason to press the button.
function acStartBody(m) {
    return {
        targetTemperature: { value: m.ac.targetTemp === undefined ? 21 : m.ac.targetTemp, unit: m.ac.unit },
        airConditioningWithoutExternalPower: m.ac.withoutPower === undefined ? true : m.ac.withoutPower
    }
}

function num(v) {
    var n = parseInt(v, 10)
    return isNaN(n) ? undefined : n
}

// get is a function name -> header value (XMLHttpRequest.getResponseHeader).
function rateInfo(get) {
    return {
        remaining: num(get("RateLimit-Remaining")),
        reset: num(get("RateLimit-Reset")),
        retryAfter: num(get("Retry-After")),
        expiresAt: ts(get("X-API-Key-Expires-At"))
    }
}

// Problem type from an application/problem+json body, e.g. "api-key-expired"; "" for about:blank or anything unreadable.
function problemType(text) {
    try {
        return String(JSON.parse(text).type || "").replace(/^.*\//, "").replace(/^about:blank$/, "")
    } catch (e) {
        return ""
    }
}

// Which user-facing message a failed request needs.
function errorKind(status, text) {
    var t = problemType(text)
    if (status === 0)
        return "offline"
    if (status === 401)
        return t === "api-key-expired" ? "expired" : "invalid"
    if (status === 403)
        return t === "operation-not-authorized" ? "refused" : "forbidden"
    if (status === 404)
        return "novehicle"
    if (status === 422)
        return t === "operation-disabled" ? "disabled" : "unsupported"
    if (status === 429)
        return t === "vehicle-not-accepting-requests" ? "declined" : "ratelimit"
    return "server"
}

// When to fetch next. Failures count against the quota, so only an offline network retries quickly;
// bad keys are rechecked every 5 minutes (those requests are free); a nearly used up quota waits for its reset.
function nextFetch(now, status, rate, minutes) {
    var wait
    if (status === 200)
        wait = minutes * 60000
    else if (status === 0)
        wait = 60000
    else if (status === 401 || status === 403 || status === 404)
        wait = 300000
    else if (rate.retryAfter !== undefined)
        wait = rate.retryAfter * 1000 + 1000
    else
        wait = 300000
    if (rate.remaining !== undefined && rate.remaining <= 2 && rate.reset !== undefined)
        wait = Math.max(wait, rate.reset * 1000 + 1000)
    return now + wait
}

// A follow-up fetch (after a command) is only worth it while the quota has room.
function quotaLeft(rate) {
    return rate.remaining === undefined || rate.remaining > 3
}

// Whole days until the key expires; null when unknown.
function keyDaysLeft(expiresAt, now) {
    return expiresAt > 0 ? Math.floor((expiresAt - now) / 86400000) : null
}

// Calendar days between t and now in local time (0 = today).
function daysAgo(t, now) {
    var a = new Date(t), b = new Date(now)
    return Math.round((new Date(b.getFullYear(), b.getMonth(), b.getDate()) - new Date(a.getFullYear(), a.getMonth(), a.getDate())) / 86400000)
}

function fmtKm(n) {
    return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, "\u00a0")
}

function fmtDuration(minutes) {
    var h = Math.floor(minutes / 60)
    var m = Math.round(minutes % 60)
    return h > 0 ? h + " h" + (m > 0 ? " " + m + " min" : "") : m + " min"
}

function unitSymbol(unit) {
    return unit === "FAHRENHEIT" ? "°F" : "°C"
}

// Material Symbols battery glyph for a charge level.
function batteryIcon(soc, charging) {
    if (charging)
        return "battery_charging_full"
    if (soc === null || soc === undefined)
        return "battery_unknown"
    return soc >= 95 ? "battery_full" : "battery_" + Math.round(soc / 100 * 6) + "_bar"
}
