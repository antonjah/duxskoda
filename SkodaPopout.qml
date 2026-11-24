import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "Skoda.js" as Skoda

PopoutComponent {
    id: popout

    required property var plugin

    readonly property var st: plugin.st
    readonly property var m: plugin.m
    readonly property bool setup: !m && (st.error === "nokey" || st.error === "novin")
    readonly property string acNow: st.acBusy > 0 ? st.acIntent : plugin.acPending ? st.acPending : ""

    headerText: I18n.trFor("duxSkoda", "Škoda")
    detailsText: I18n.trFor("duxSkoda", "Connected via MyŠkoda")
    showCloseButton: true

    function hhmm(ms) {
        return Qt.formatTime(new Date(ms), "HH:mm")
    }

    function shortPath(p) {
        return p.replace(plugin.home, "~")
    }

    function partLabel(part) {
        switch (part) {
        case "doors": return I18n.trFor("duxSkoda", "Doors")
        case "windows": return I18n.trFor("duxSkoda", "Windows")
        case "trunk": return I18n.trFor("duxSkoda", "Trunk")
        default: return I18n.trFor("duxSkoda", "Bonnet")
        }
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            visible: !popout.m && popout.st.error === ""
            width: parent.width
            text: I18n.trFor("duxSkoda", "Loading…")
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeMedium
        }

        Notice {
            visible: popout.setup
            width: parent.width
            icon: "key"
            tint: Theme.primary
            title: I18n.trFor("duxSkoda", "Connect your Škoda")
            text: I18n.trFor("duxSkoda", "1. In the MyŠkoda app (8.16 or newer), create an API key for your car.\n2. Save the key alone in a file: %1\n3. Save your VIN alone in a file: %2\n\n%3")
                .arg(popout.shortPath(popout.plugin.tokenFile)).arg(popout.shortPath(popout.plugin.vinFile))
                .arg(popout.plugin.errorText(popout.st.error, 0))
            textColor: Theme.surfaceVariantText
        }

        Notice {
            visible: popout.st.error !== "" && !popout.setup
            width: parent.width
            text: popout.plugin.errorText(popout.st.error, popout.st.errorStatus) + (popout.m ? " · " + I18n.trFor("duxSkoda", "showing last data") : "")
            textColor: Theme.error
        }

        Notice {
            visible: !!popout.m && popout.plugin.keyDays <= 14 && popout.st.error !== "expired"
            width: parent.width
            icon: "schedule"
            tint: Theme.warning
            text: (popout.plugin.keyDays <= 0
                ? I18n.trFor("duxSkoda", "The API key expires today.")
                : popout.plugin.keyDays === 1
                    ? I18n.trFor("duxSkoda", "The API key expires in 1 day.")
                    : I18n.trFor("duxSkoda", "The API key expires in %1 days.").arg(popout.plugin.keyDays))
                + " " + I18n.trFor("duxSkoda", "Create a new one in the MyŠkoda app.")
        }

        CarTile {
            visible: !!popout.m
            width: parent.width
            m: popout.m
            accent: popout.plugin.accent
            now: popout.plugin.now
        }

        Row {
            id: chargeRow
            visible: !!popout.m && popout.m.charging
            width: parent.width
            spacing: Theme.spacingS

            StatTile {
                width: (chargeRow.width - Theme.spacingS) / 2
                label: I18n.trFor("duxSkoda", "Power")
                icon: "bolt"
                accent: Theme.success
                value: popout.m && popout.m.powerKw !== null ? popout.m.powerKw.toFixed(1) + " kW" : "–"
                sub: popout.m ? popout.m.chargeType : ""
            }

            StatTile {
                width: (chargeRow.width - Theme.spacingS) / 2
                label: I18n.trFor("duxSkoda", "Time left")
                icon: "schedule"
                accent: Theme.primary
                value: popout.m && popout.m.minutesLeft !== null ? Skoda.fmtDuration(popout.m.minutesLeft) : "–"
                sub: popout.m && popout.m.fullAt > 0 ? I18n.trFor("duxSkoda", "Full at %1").arg(popout.hhmm(popout.m.fullAt)) : ""
            }
        }

        Row {
            id: statRow
            readonly property bool hasLock: !!popout.m && popout.m.hasStatus
            readonly property bool hasOdometer: !!popout.m && popout.m.odometerKm !== null
            readonly property real tileWidth: hasLock && hasOdometer ? (width - Theme.spacingS) / 2 : width
            visible: hasLock || hasOdometer
            width: parent.width
            spacing: Theme.spacingS

            StatTile {
                readonly property bool open: !!popout.m && popout.m.open.length > 0
                visible: statRow.hasLock
                width: statRow.tileWidth
                label: I18n.trFor("duxSkoda", "Car")
                icon: !popout.m || popout.m.lock === "locked" ? "lock" : "lock_open"
                accent: !popout.m ? Theme.surfaceText : popout.m.lock === "locked" ? Theme.success : popout.m.lock === "unlocked" ? Theme.warning : Theme.surfaceVariantText
                value: !popout.m ? "" : open ? I18n.trFor("duxSkoda", "Open") : popout.m.lock === "locked" ? I18n.trFor("duxSkoda", "Locked") : popout.m.lock === "unlocked" ? I18n.trFor("duxSkoda", "Unlocked") : I18n.trFor("duxSkoda", "Unknown")
                sub: !popout.m ? "" : open ? popout.m.open.map(popout.partLabel).join(", ") : popout.m.closed ? I18n.trFor("duxSkoda", "Doors and windows closed") : ""
            }

            StatTile {
                visible: statRow.hasOdometer
                width: statRow.tileWidth
                label: I18n.trFor("duxSkoda", "Odometer")
                icon: "speed"
                accent: Theme.primary
                value: statRow.hasOdometer ? Skoda.fmtKm(popout.m.odometerKm) + " km" : ""
                sub: I18n.trFor("duxSkoda", "Total")
            }
        }

        AcTile {
            visible: !!popout.m && (popout.m.ac.state !== "" || popout.m.canStartAc)
            width: parent.width
            m: popout.m
            now: popout.plugin.now
            pending: popout.acNow
            failure: popout.st.acFailed ? popout.plugin.errorText(popout.st.acResult, 0) : ""
            onStart: popout.plugin.acCommand(true)
            onStop: popout.plugin.acCommand(false)
        }

        StyledText {
            visible: !!popout.m && popout.m.partial
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.trFor("duxSkoda", "Some data is unavailable right now")
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }

        StyledText {
            visible: popout.st.updatedAt > 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.trFor("duxSkoda", "Updated %1 · right-click the bar widget to refresh").arg(popout.hhmm(popout.st.updatedAt))
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
    }
}
