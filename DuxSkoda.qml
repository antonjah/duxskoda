import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "Skoda.js" as Skoda

PluginComponent {
    id: root

    layerNamespacePlugin: "skoda"

    readonly property string home: Quickshell.env("HOME")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
    readonly property string tokenFile: (String(setting("tokenFile", "")) || (configHome + "/skoda/token")).replace(/^~/, home)
    readonly property string vinFile: (String(setting("vinFile", "")) || (configHome + "/skoda/vin")).replace(/^~/, home)
    readonly property int refreshMinutes: Math.max(10, Number(setting("refreshMinutes", 0)) || 15)
    // ponytail: overridable only so tests can point at a mock server.
    readonly property string apiUrl: pluginData.apiUrl || ""

    // Declared settings (e.g. written by home-manager) win over the settings page.
    property var declared: ({})

    function setting(key, fallback) {
        const v = declared[key] !== undefined ? declared[key] : pluginData[key]
        return v !== undefined && v !== null ? v : fallback
    }

    function readDeclared() {
        try {
            declared = JSON.parse(declaredView.text())
        } catch (e) {
            declared = ({})
        }
    }

    FileView {
        id: declaredView
        path: root.configHome + "/skoda/config.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.readDeclared()
        onLoadFailed: root.declared = ({})
        onFileChanged: reload()
    }

    Component.onCompleted: readDeclared()

    // One shared state for every bar instance (one per screen) so only one request goes out.
    PluginGlobalVar {
        id: shared
        varName: "state"
        defaultValue: ({
            model: null, error: "", errorStatus: 0, nextAt: 0, fetching: 0, fetchedAt: 0, updatedAt: 0, key: "",
            expiresAt: 0, rate: ({}), acBusy: 0, acIntent: "", acResult: "", acFailed: false, acPending: "", acPendingAt: 0
        })
    }

    readonly property var st: shared.value
    property real now: Date.now()
    readonly property var m: st.model
    readonly property int keyDays: {
        const d = Skoda.keyDaysLeft(st.expiresAt, now)
        return d === null ? 9999 : d
    }
    readonly property bool lowCharge: !!m && m.soc !== null && m.soc < 20
    readonly property color accent: !m ? Theme.primary : m.charging ? Theme.success : lowCharge ? Theme.error : Theme.primary
    readonly property color pillColor: !m ? (st.error ? Theme.error : Theme.surfaceText) : m.charging ? Theme.success : lowCharge ? Theme.error : Theme.surfaceText
    readonly property string pillIcon: st.error && m ? "cloud_off" : "electric_car"
    readonly property string pillNumber: m && m.soc !== null ? String(m.soc) : (st.error ? "!" : "…")
    readonly property string pillText: pillNumber + (m && m.soc !== null ? " %" : "")
    // An A/C request is pending until the car reports the new state (or a few minutes pass).
    readonly property bool acPending: st.acPending !== "" && now - st.acPendingAt < 180000 && !!m && (st.acPending === "start") !== m.ac.on

    FileView {
        id: tokenView
        path: root.tokenFile
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }

    FileView {
        id: vinView
        path: root.vinFile
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }

    function readFile(view) {
        try {
            return view.text().trim()
        } catch (e) {
            return ""
        }
    }

    function vinValid() {
        return /^[A-Za-z0-9]{17}$/.test(readFile(vinView))
    }

    function setState(patch) {
        shared.set(Object.assign({}, shared.value, patch))
    }

    function request(method, url, headers, body, cb) {
        const x = new XMLHttpRequest()
        x.open(method, url)
        for (const k in headers)
            x.setRequestHeader(k, headers[k])
        x.onreadystatechange = () => {
            if (x.readyState === XMLHttpRequest.DONE)
                cb(x.status, x.responseText, Skoda.rateInfo(n => x.getResponseHeader(n)))
        }
        // send(null) would put the text "null" on the wire.
        if (body === null)
            x.send()
        else
            x.send(body)
    }

    function errorText(kind, status) {
        switch (kind) {
        case "nokey": return I18n.trFor("duxSkoda", "No API key found")
        case "novin": return I18n.trFor("duxSkoda", "No valid VIN found")
        case "offline": return I18n.trFor("duxSkoda", "Offline")
        case "expired": return I18n.trFor("duxSkoda", "API key expired. Create a new one in the MyŠkoda app")
        case "invalid": return I18n.trFor("duxSkoda", "Invalid API key")
        case "forbidden": return I18n.trFor("duxSkoda", "The API key does not cover this car")
        case "novehicle": return I18n.trFor("duxSkoda", "No car found for this VIN")
        case "ratelimit": return I18n.trFor("duxSkoda", "Request limit reached, waiting before the next try")
        case "declined": return I18n.trFor("duxSkoda", "The car declined the request, try again later")
        case "refused": return I18n.trFor("duxSkoda", "The car refused the request")
        case "disabled": return I18n.trFor("duxSkoda", "This is currently disabled for your car")
        case "unsupported": return I18n.trFor("duxSkoda", "Your car does not support this")
        case "badresponse": return I18n.trFor("duxSkoda", "Bad response from Škoda")
        case "nodata": return I18n.trFor("duxSkoda", "The car reported no data")
        default: return I18n.trFor("duxSkoda", "Škoda server error (HTTP %1)").arg(status)
        }
    }

    function finish(patch) {
        setState(Object.assign({ fetching: 0 }, patch))
    }

    function result(status, text, rate) {
        const t = Date.now()
        const parsed = status === 200 ? Skoda.parse(text) : null
        const kind = status === 200 ? (parsed.error || "") : Skoda.errorKind(status, text)
        finish({
            model: kind ? shared.value.model : parsed,
            error: kind,
            errorStatus: status,
            acFailed: kind ? shared.value.acFailed : false,
            updatedAt: kind ? shared.value.updatedAt : t,
            expiresAt: rate.expiresAt || shared.value.expiresAt,
            rate: rate,
            nextAt: Skoda.nextFetch(t, status, rate, refreshMinutes)
        })
    }

    function fetchVehicle() {
        const key = readFile(tokenView)
        const vin = readFile(vinView)
        // Missing files cost nothing, so they are rechecked every minute until they appear.
        if (key === "")
            return finish({ error: "nokey", nextAt: Date.now() + 60000 })
        if (!vinValid())
            return finish({ error: "novin", nextAt: Date.now() + 60000 })
        request("GET", Skoda.vehicleUrl(apiUrl, vin), { "X-API-Key": key }, null, result)
    }

    function refresh() {
        const s = shared.value
        // A request stuck for over a minute is treated as dead.
        if (s.fetching && Date.now() - s.fetching < 60000)
            return
        setState({ fetching: Date.now(), fetchedAt: Date.now(), key: fetchKey })
        fetchVehicle()
    }

    // Right-click is a manual refresh; the quota is small, so a burst of clicks must not use it up.
    function refreshManual() {
        if (Date.now() - shared.value.fetchedAt >= 30000)
            refresh()
    }

    // Starts or stops the air conditioning. The car takes a while to report back, so one follow-up fetch
    // is scheduled (if the quota has room) and the tile shows the request as pending meanwhile.
    function acCommand(start) {
        const s = shared.value
        if (!s.model || (s.acBusy && Date.now() - s.acBusy < 30000))
            return
        const key = readFile(tokenView)
        if (key === "" || !vinValid())
            return
        setState({ acBusy: Date.now(), acIntent: start ? "start" : "stop", acResult: "", acFailed: false })
        const url = Skoda.vehicleUrl(apiUrl, readFile(vinView)) + "/air-conditioning/" + (start ? "start" : "stop")
        const headers = start ? { "X-API-Key": key, "Content-Type": "application/json" } : { "X-API-Key": key }
        request("POST", url, headers, start ? JSON.stringify(Skoda.acStartBody(s.model)) : null, (status, text, rate) => {
            const ok = status === 202 || status === 200
            const t = Date.now()
            setState({
                acBusy: 0,
                acFailed: !ok,
                acResult: ok ? "" : Skoda.errorKind(status, text),
                acPending: ok ? (start ? "start" : "stop") : "",
                acPendingAt: t,
                rate: rate,
                nextAt: ok && Skoda.quotaLeft(rate) ? t + 30000 : shared.value.nextAt
            })
        })
    }

    function refreshIfDue() {
        now = Date.now()
        if (now >= st.nextAt)
            refresh()
    }

    // Changing where data comes from should not wait for the next interval.
    // The delay lets FileView load a changed path before it is read.
    readonly property string fetchKey: tokenFile + "|" + vinFile + "|" + apiUrl
    onFetchKeyChanged: {
        if (shared.value.key !== fetchKey)
            setState({ nextAt: 0 })
        keyDebounce.restart()
    }

    Timer {
        id: keyDebounce
        interval: 500
        onTriggered: root.refreshIfDue()
    }

    // The network is only hit when due; the clock-dependent parts of the UI refresh each minute.
    Timer {
        interval: 60000
        repeat: true
        running: root.surfaceLive
        triggeredOnStart: true
        onTriggered: root.refreshIfDue()
    }

    pillRightClickAction: () => root.refreshManual()

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: root.pillIcon
                size: root.iconSize
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.pillText
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DIcon {
                name: root.pillIcon
                size: root.iconSize
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.pillNumber
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: !!root.m && root.m.soc !== null
                text: "%"
                font.pixelSize: root.textSize - 2
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 460
    popoutHeight: 0

    popoutContent: Component {
        SkodaPopout { plugin: root }
    }
}
