import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { loadScript } from "./qml-script.mjs";

const S = loadScript(new URL("../Skoda.js", import.meta.url));
const fixture = JSON.parse(readFileSync(new URL("./fixtures/vehicle.json", import.meta.url), "utf8"));
// Objects made inside the vm context have another Object prototype; compare plain copies.
const clone = (o) => JSON.parse(JSON.stringify(o));
const NOW = Date.parse("2026-11-24T15:00:00Z");

test("parse reads the real response", () => {
    const m = S.parse(fixture);
    assert.equal(m.name, "Enyaq");
    assert.equal(m.soc, 76);
    assert.equal(m.rangeKm, 270);
    assert.equal(m.target, 100);
    assert.equal(m.status, "unplugged");
    assert.equal(m.charging, false);
    assert.equal(m.odometerKm, 100363);
    assert.equal(m.lock, "locked");
    assert.equal(m.hasStatus, true);
    assert.equal(m.closed, true);
    assert.equal(m.partial, false);
    assert.deepEqual(clone(m.open), []);
    assert.equal(m.ac.state, "HEATING");
    assert.equal(m.ac.on, true);
    assert.equal(m.ac.targetTemp, 21);
    assert.equal(m.canStartAc, true);
    assert.equal(m.canStopAc, true);
    assert.deepEqual(clone(m.errors), []);
});

test("parse accepts a JSON string body", () => {
    assert.equal(S.parse(JSON.stringify(fixture)).soc, 76);
});

test("parse survives every fractional-second format the API sends (Qt is stricter than node)", () => {
    assert.equal(S.ts("2026-11-24T14:59:09.089322726Z"), Date.parse("2026-11-24T14:59:09.089Z"));
    assert.equal(S.ts("2026-11-24T14:28:29.3Z"), Date.parse("2026-11-24T14:28:29.300Z"));
    assert.equal(S.ts("2026-11-24T14:28:30.98Z"), Date.parse("2026-11-24T14:28:30.980Z"));
    assert.equal(S.ts("2026-11-24T14:28:30.982Z"), Date.parse("2026-11-24T14:28:30.982Z"));
    assert.equal(S.ts("2026-11-24T14:36:34Z"), Date.parse("2026-11-24T14:36:34Z"));
    assert.equal(S.ts(""), 0);
    assert.equal(S.ts(undefined), 0);
    assert.equal(S.parse(fixture).ac.reachAt, Date.parse("2026-11-24T14:59:09.089Z"));
});

test("seenAt is the battery capture time", () => {
    assert.equal(S.parse(fixture).seenAt, Date.parse("2026-11-24T14:28:34Z"));
});

test("parse rejects garbage and empty vehicles", () => {
    assert.equal(S.parse("not json").error, "badresponse");
    assert.equal(S.parse({}).error, "badresponse");
    assert.equal(S.parse({ vehicle: { vin: "X", name: "Enyaq" }, errors: [] }).error, "nodata");
});

test("parse keeps partial data and reports the API's errors", () => {
    const r = clone(fixture);
    delete r.vehicle.status;
    delete r.vehicle.airConditioning;
    delete r.vehicle.operations;
    r.errors = [{ type: "VEHICLE_STATUS_UNAVAILABLE", description: "x" }];
    const m = S.parse(r);
    assert.equal(m.soc, 76);
    assert.equal(m.lock, "unknown");
    // No status section means unknown, never "closed".
    assert.equal(m.hasStatus, false);
    assert.equal(m.closed, false);
    assert.equal(m.partial, true);
    assert.equal(m.ac.state, "");
    assert.equal(m.ac.on, false);
    assert.equal(m.canStartAc, false);
    assert.deepEqual(clone(m.errors), ["VEHICLE_STATUS_UNAVAILABLE"]);
});

test("an error about the car picture alone is not partial data", () => {
    const r = clone(fixture);
    r.errors = [{ type: "RENDER_UNAVAILABLE", description: "x" }];
    assert.equal(S.parse(r).partial, false);
});

test("missing values stay unknown instead of becoming zero", () => {
    const r = clone(fixture);
    delete r.vehicle.charging.status.battery;
    delete r.vehicle.odometer;
    const m = S.parse(r);
    assert.equal(m.soc, null);
    assert.equal(m.rangeKm, null);
    assert.equal(m.odometerKm, null);
});

test("charge status follows the process, then the plug", () => {
    assert.equal(S.chargeStatus({ state: "CHARGING", plugConnectionState: "CONNECTED" }), "charging");
    assert.equal(S.chargeStatus({ state: "CHARGING_INTERRUPTED" }), "interrupted");
    assert.equal(S.chargeStatus({ state: "READY_FOR_CHARGING" }), "plugged");
    assert.equal(S.chargeStatus({ state: "CONSERVING" }), "plugged");
    assert.equal(S.chargeStatus({ state: "CONNECT_CABLE", plugConnectionState: "DISCONNECTED" }), "unplugged");
    // The API omits state for plugged-in-but-idle; the plug still tells.
    assert.equal(S.chargeStatus({ plugConnectionState: "CONNECTED", plugLockState: "UNLOCKED" }), "plugged");
    assert.equal(S.chargeStatus({ plugConnectionState: "DISCONNECTED" }), "unplugged");
    assert.equal(S.chargeStatus({}), "unknown");
    // A new value the client does not know must not break anything.
    assert.equal(S.chargeStatus({ state: "SOMETHING_NEW", plugConnectionState: "CONNECTED" }), "plugged");
});

test("charging details come through while charging", () => {
    const r = clone(fixture);
    Object.assign(r.vehicle.charging.status, { state: "CHARGING", plugConnectionState: "CONNECTED", chargePowerInKw: 10.8, remainingTimeToFullyChargedInMinutes: 95, chargeType: "AC", fullyChargedAt: "2026-11-24T16:35:00Z" });
    const m = S.parse(r);
    assert.equal(m.charging, true);
    assert.equal(m.powerKw, 10.8);
    assert.equal(m.minutesLeft, 95);
    assert.equal(m.chargeType, "AC");
    assert.equal(m.fullAt, Date.parse("2026-11-24T16:35:00Z"));
});

test("lock and open parts", () => {
    const r = clone(fixture);
    Object.assign(r.vehicle.status.overall, { reliableLockStatus: "UNLOCKED", doors: "OPEN", windows: "OPEN" });
    r.vehicle.status.detail.trunk = "OPEN";
    const m = S.parse(r);
    assert.equal(m.lock, "unlocked");
    assert.equal(m.closed, false);
    assert.deepEqual(clone(m.open), ["doors", "windows", "trunk"]);
});

test("air conditioning states", () => {
    for (const [state, on] of [["OFF", false], ["COMPLETED", false], ["UNKNOWN", false], ["COOLING", true], ["HEATING", true], ["HEATING_AUXILIARY", true], ["VENTILATION", true]]) {
        const r = clone(fixture);
        r.vehicle.airConditioning.state = state;
        assert.equal(S.parse(r).ac.on, on, state);
    }
});

test("A/C start body uses the car's own target and does not demand external power", () => {
    assert.deepEqual(clone(S.acStartBody(S.parse(fixture))), { targetTemperature: { value: 21, unit: "CELSIUS" }, airConditioningWithoutExternalPower: true });
    const r = clone(fixture);
    delete r.vehicle.airConditioning.targetTemperature;
    r.vehicle.airConditioning.airConditioningWithoutExternalPower = false;
    assert.deepEqual(clone(S.acStartBody(S.parse(r))), { targetTemperature: { value: 21, unit: "CELSIUS" }, airConditioningWithoutExternalPower: false });
});

test("rateInfo reads headers and tolerates missing ones", () => {
    const h = { "RateLimit-Remaining": "7", "RateLimit-Reset": "153", "X-API-Key-Expires-At": "2027-05-23T14:31:20.609Z" };
    const r = S.rateInfo((k) => h[k] ?? "");
    assert.equal(r.remaining, 7);
    assert.equal(r.reset, 153);
    assert.equal(r.retryAfter, undefined);
    assert.equal(r.expiresAt, Date.parse("2027-05-23T14:31:20.609Z"));
    const none = S.rateInfo(() => null);
    assert.equal(none.remaining, undefined);
    assert.equal(none.expiresAt, 0);
});

test("errorKind tells the documented problems apart", () => {
    const p = (t) => JSON.stringify({ type: "https://public.api.connect.skoda-auto.cz/problems/" + t });
    assert.equal(S.errorKind(0, ""), "offline");
    assert.equal(S.errorKind(401, p("api-key-expired")), "expired");
    assert.equal(S.errorKind(401, JSON.stringify({ type: "about:blank" })), "invalid");
    assert.equal(S.errorKind(403, p("api-key-not-authorized")), "forbidden");
    assert.equal(S.errorKind(403, p("operation-not-authorized")), "refused");
    assert.equal(S.errorKind(404, ""), "novehicle");
    assert.equal(S.errorKind(422, p("operation-disabled")), "disabled");
    assert.equal(S.errorKind(422, p("operation-not-supported")), "unsupported");
    assert.equal(S.errorKind(429, p("rate-limit-exceeded")), "ratelimit");
    assert.equal(S.errorKind(429, p("vehicle-not-accepting-requests")), "declined");
    assert.equal(S.errorKind(500, "<html>"), "server");
    assert.equal(S.errorKind(503, ""), "server");
});

test("nextFetch backs off by failure type and respects the quota", () => {
    const none = {};
    assert.equal(S.nextFetch(NOW, 200, none, 15), NOW + 15 * 60000);
    assert.equal(S.nextFetch(NOW, 0, none, 15), NOW + 60000);
    assert.equal(S.nextFetch(NOW, 401, none, 15), NOW + 300000);
    assert.equal(S.nextFetch(NOW, 429, { retryAfter: 600 }, 15), NOW + 601000);
    assert.equal(S.nextFetch(NOW, 429, none, 15), NOW + 300000);
    assert.equal(S.nextFetch(NOW, 503, { retryAfter: 30 }, 15), NOW + 31000);
    // Nearly empty quota waits for its reset even when the interval is shorter.
    assert.equal(S.nextFetch(NOW, 200, { remaining: 1, reset: 3000 }, 15), NOW + 3001000);
    assert.equal(S.nextFetch(NOW, 200, { remaining: 5, reset: 3000 }, 15), NOW + 15 * 60000);
});

test("quotaLeft keeps a reserve", () => {
    assert.equal(S.quotaLeft({}), true);
    assert.equal(S.quotaLeft({ remaining: 4 }), true);
    assert.equal(S.quotaLeft({ remaining: 3 }), false);
});

test("keyDaysLeft", () => {
    assert.equal(S.keyDaysLeft(0, NOW), null);
    assert.equal(S.keyDaysLeft(NOW + 5.5 * 86400000, NOW), 5);
    assert.equal(S.keyDaysLeft(NOW - 1000, NOW), -1);
});

test("formatting", () => {
    assert.equal(S.fmtKm(100363), "100\u00a0363");
    assert.equal(S.fmtKm(950), "950");
    assert.equal(S.fmtDuration(95), "1 h 35 min");
    assert.equal(S.fmtDuration(120), "2 h");
    assert.equal(S.fmtDuration(45), "45 min");
    assert.equal(S.unitSymbol("CELSIUS"), "°C");
    assert.equal(S.unitSymbol("FAHRENHEIT"), "°F");
    assert.equal(S.vehicleUrl("http://x:1/", "TMB1"), "http://x:1/api/v1/vehicles/TMB1");
    assert.equal(S.vehicleUrl("", "TMB1"), "https://public.api.connect.skoda-auto.cz/api/v1/vehicles/TMB1");
});
