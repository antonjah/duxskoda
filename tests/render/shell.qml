// Quickshell config for tests/render.sh; do not run it directly.
// Hosts the real plugin with the real DMS components and writes one PNG per scene.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Common as DC

ShellRoot {
    id: shell

    readonly property string pluginDir: Quickshell.env("DUXSKODA_DIR")
    readonly property string shotDir: Quickshell.env("DUXSKODA_SHOTS")
    readonly property string tokenDir: Quickshell.env("DUXSKODA_TOKENS")
    readonly property string apiUrl: Quickshell.env("DUXSKODA_API")
    readonly property string pid: "duxSkoda"

    // key: file under tokenDir holding the API key (its name is the mock server's scenario; "missing" = no file).
    // vin: file under tokenDir (default a valid VIN). swap: key to switch to after the first load.
    // click: press the A/C button once the popout is up. twin: a second bar instance. declared: config.json content.
    readonly property var allScenes: [
        { name: "heating", key: "heating" },
        { name: "idle", key: "idle", vertical: true },
        { name: "charging", key: "charging" },
        { name: "plugged", key: "plugged" },
        { name: "lowbat", key: "lowbat" },
        { name: "open", key: "open" },
        { name: "partial", key: "partial" },
        { name: "noac", key: "noac" },
        { name: "expiring", key: "expiring" },
        { name: "lowquota", key: "lowquota" },
        { name: "acstart", key: "idle", click: true },
        { name: "acstop", key: "heating", click: true },
        { name: "acdisabled", key: "acdisabled", click: true },
        { name: "acdeclined", key: "acdeclined", click: true },
        { name: "expired", key: "expired" },
        { name: "stale", key: "idle", swap: "expired" },
        { name: "forbidden", key: "forbidden" },
        { name: "ratelimit", key: "ratelimit" },
        { name: "server", key: "server" },
        { name: "invalid", key: "bogus" },
        { name: "nokey", key: "missing" },
        { name: "novin", key: "idle", vin: "missing" },
        { name: "badvin", key: "idle", vin: "vin-bad" },
        { name: "offline", key: "idle", api: "http://127.0.0.1:1" },
        { name: "twoscreens", key: "idle", twin: true },
        { name: "declared", key: "idle", declared: { refreshMinutes: 30 } }
    ]
    // DUXSKODA_ONLY="a b" renders just those scenes (fast iteration). DUXSKODA_ONLY="real" makes one GET against
    // the real API with the key and VIN files in DUXSKODA_REAL_DIR; it never sends a command and is never in a full run.
    readonly property string only: Quickshell.env("DUXSKODA_ONLY") || ""
    readonly property string realDir: Quickshell.env("DUXSKODA_REAL_DIR") || ""
    readonly property var scenes: only === "real" ? [{ name: "real", real: true }] : only ? allScenes.filter(s => only.split(" ").indexOf(s.name) >= 0) : allScenes
    property int sceneIndex: -1

    // The plugin reads this declared-settings file; each scene rewrites it.
    FileView {
        id: declaredFile
        path: Quickshell.env("XDG_CONFIG_HOME") + "/skoda/config.json"
        blockWrites: true
        printErrors: false
    }

    function find(item, name) {
        if (item.objectName === name)
            return item
        for (const child of item.children) {
            const hit = find(child, name)
            if (hit)
                return hit
        }
        return null
    }

    property var widgets: []
    property var scene: null
    property int tries: 0
    property var swapFrom: 0

    Component.onCompleted: {
        DC.Style.theme = Theme
        DC.Style.settings = SettingsData
        DC.I18n.backend = I18n
        DC.Paths.backend = Paths
        DC.Log.backend = Log
        DC.Host.session = SessionService
        DC.Host.cache = CacheData
        DC.Host.files = FilesService
        start.start()
    }

    Timer {
        id: start
        interval: 300
        onTriggered: shell.nextScene()
    }

    FloatingWindow {
        implicitWidth: 540
        implicitHeight: 1240
        color: Theme.surface
        visible: true

        Item {
            id: widgetHost
            width: 0
            height: 0
        }

        Column {
            id: stage
            padding: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingL

                Rectangle {
                    id: pillChip
                    width: pillHost.childrenRect.width + Theme.spacingM * 2
                    height: 34
                    radius: Theme.cornerRadius
                    color: Theme.chipSurface

                    Item {
                        id: pillHost
                        x: Theme.spacingM
                        height: parent.height
                    }
                }

                Rectangle {
                    id: verticalChip
                    width: 40
                    height: verticalHost.childrenRect.height + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.chipSurface
                    visible: !!(shell.scene && shell.scene.vertical)

                    Item {
                        id: verticalHost
                        y: Theme.spacingM
                        width: parent.width
                    }
                }
            }

            Rectangle {
                id: popoutHost
                width: 460
                height: childrenRect.height + PopoutMetrics.contentPadding * 2
                radius: Theme.cornerRadius * 1.5
                color: Theme.surfaceContainer
                border.color: Theme.outlineVariant
                border.width: 1
            }
        }
    }

    function clearScene() {
        widgets.forEach(w => w.destroy())
        widgets = []
        for (const host of [pillHost, verticalHost, popoutHost])
            for (let i = host.children.length - 1; i >= 0; i--)
                host.children[i].destroy()
    }

    function spawn() {
        const c = Qt.createComponent("file://" + pluginDir + "/DuxSkoda.qml")
        if (c.status === Component.Error) {
            console.log("SKODA ERROR " + c.errorString())
            return null
        }
        const w = c.createObject(widgetHost, { pluginService: PluginService, pluginId: pid })
        widgets.push(w)
        return w
    }

    function nextScene() {
        clearScene()
        sceneIndex++
        if (sceneIndex >= scenes.length) {
            console.log("SKODA done")
            Qt.callLater(Qt.quit)
            return
        }
        scene = scenes[sceneIndex]
        PluginService.globalVars = ({})
        if (scene.real) {
            SettingsData.setPluginSetting(pid, "apiUrl", "")
            SettingsData.setPluginSetting(pid, "tokenFile", realDir + "/token")
            SettingsData.setPluginSetting(pid, "vinFile", realDir + "/vin")
        } else {
            SettingsData.setPluginSetting(pid, "apiUrl", scene.api || apiUrl)
            SettingsData.setPluginSetting(pid, "tokenFile", tokenDir + "/" + scene.key)
            SettingsData.setPluginSetting(pid, "vinFile", tokenDir + "/" + (scene.vin || "vin-ok"))
        }
        SettingsData.setPluginSetting(pid, "refreshMinutes", "15")
        declaredFile.setText(JSON.stringify(scene.declared || {}))
        spawn()
        if (scene.twin)
            spawn()
        tries = 0
        swapFrom = 0
        poll.start()
    }

    // A fetch is finished once the shared state has a nextAt and nothing in flight.
    Timer {
        id: poll
        interval: 25
        repeat: true
        onTriggered: {
            tries++
            const st = shell.widgets[0].st
            const done = st.fetchedAt > shell.swapFrom && st.fetching === 0 && st.nextAt > 0
            if (!done && tries < 400)
                return
            if (shell.scene.swap && shell.swapFrom === 0) {
                shell.swapFrom = st.fetchedAt
                SettingsData.setPluginSetting(shell.pid, "tokenFile", shell.tokenDir + "/" + shell.scene.swap)
                PluginService.pluginDataChanged(shell.pid)
                swapTimer.start()
                shell.tries = 0
                return
            }
            stop()
            shell.build()
        }
    }

    // The settings change reaches FileView asynchronously in the real shell too.
    Timer {
        id: swapTimer
        interval: 150
        onTriggered: shell.widgets[0].refresh()
    }

    function build() {
        const w = widgets[0]
        const pill = w.horizontalBarPill.createObject(pillHost)
        pill.anchors.verticalCenter = pillHost.verticalCenter
        if (scene.vertical)
            w.verticalBarPill.createObject(verticalHost).anchors.horizontalCenter = verticalHost.horizontalCenter
        w.popoutContent.createObject(popoutHost, {
            width: popoutHost.width - PopoutMetrics.contentPadding * 2,
            x: PopoutMetrics.contentPadding,
            y: PopoutMetrics.contentPadding
        })
        if (scene.click) {
            tries = 0
            clickTimer.start()
        } else {
            settle.start()
        }
    }

    // Presses the A/C button, then waits for the command to finish (success shows as pending, failure as acFailed).
    Timer {
        id: clickTimer
        interval: 100
        onTriggered: {
            const button = shell.find(popoutHost, "acButton")
            if (button)
                button.clicked()
            else
                console.log("SKODA ERROR no A/C button in " + shell.scene.name)
            waitCommand.start()
        }
    }

    Timer {
        id: waitCommand
        interval: 25
        repeat: true
        onTriggered: {
            shell.tries++
            const st = shell.widgets[0].st
            if ((st.acBusy === 0 && (st.acPending !== "" || st.acFailed)) || shell.tries > 200) {
                stop()
                settle.start()
            }
        }
    }

    function report() {
        const w = widgets[0]
        const st = w.st
        console.log("SKODA " + scene.name + " pill=" + w.pillText + " soc=" + (w.m ? w.m.soc : "none") + " status=" + (w.m ? w.m.status : "none")
            + " error=" + JSON.stringify(st.error) + " ac=" + (w.m ? w.m.ac.state : "none")
            + " pending=" + (st.acBusy > 0 ? st.acIntent : w.acPending ? st.acPending : "-") + " acfail=" + (st.acFailed ? st.acResult : "-")
            + " nextIn=" + Math.round((st.nextAt - Date.now()) / 1000) + " keyDays=" + (w.keyDays === 9999 ? "none" : w.keyDays)
            + " refresh=" + w.refreshMinutes + " twinSame=" + (widgets.length > 1 ? (widgets[1].st.nextAt === st.nextAt) : "n/a"))
    }

    Timer {
        id: settle
        interval: 250
        onTriggered: {
            shell.report()
            stage.grabToImage(result => {
                result.saveToFile(shell.shotDir + "/" + shell.scene.name + ".png")
                shell.nextScene()
            })
        }
    }
}
