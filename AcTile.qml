import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import "Skoda.js" as Skoda

Rectangle {
    id: tile

    property var m: null
    property real now: Date.now()
    // "start" or "stop" while a request is on its way or waiting for the car to report back.
    property string pending: ""
    // A finished command's failure, already translated; empty when there is none.
    property string failure: ""

    signal start
    signal stop

    readonly property var ac: m ? m.ac : null
    readonly property bool on: !!ac && ac.on
    readonly property color accent: pending !== "" ? Theme.primary : on ? Theme.primary : Theme.surfaceVariantText
    readonly property string glyph: {
        switch (ac ? ac.state : "") {
        case "COOLING": return "ac_unit"
        case "HEATING":
        case "HEATING_AUXILIARY": return "mode_heat"
        case "VENTILATION": return "air"
        default: return "device_thermostat"
        }
    }
    readonly property string statusText: {
        if (pending === "start")
            return I18n.trFor("duxSkoda", "Starting…")
        if (pending === "stop")
            return I18n.trFor("duxSkoda", "Stopping…")
        switch (ac ? ac.state : "") {
        case "COOLING": return I18n.trFor("duxSkoda", "Cooling")
        case "HEATING":
        case "HEATING_AUXILIARY": return I18n.trFor("duxSkoda", "Heating")
        case "VENTILATION": return I18n.trFor("duxSkoda", "Ventilating")
        case "COMPLETED": return I18n.trFor("duxSkoda", "Finished")
        case "OFF": return I18n.trFor("duxSkoda", "Off")
        default: return I18n.trFor("duxSkoda", "Unknown")
        }
    }
    readonly property string temp: ac && ac.targetTemp !== undefined ? ac.targetTemp + " " + Skoda.unitSymbol(ac.unit) : ""
    readonly property string info: {
        if (failure !== "")
            return failure
        if (pending === "" && on && ac.reachAt > now)
            return I18n.trFor("duxSkoda", "Reaches %1 at %2").arg(temp).arg(Qt.formatTime(new Date(ac.reachAt), "HH:mm"))
        if (pending === "" && on && ac.reachAt > 0)
            return I18n.trFor("duxSkoda", "Target temperature reached")
        return ""
    }
    readonly property bool canAct: pending === "" && !!m && (on ? m.canStopAc : m.canStartAc)

    implicitHeight: body.height + Theme.spacingL * 2
    radius: Theme.cornerRadius * 1.5
    color: Theme.surfaceContainerHigh

    Column {
        id: body
        x: Theme.spacingL
        y: Theme.spacingL
        width: parent.width - Theme.spacingL * 2
        spacing: Theme.spacingM

        Item {
            width: parent.width
            height: badge.height

            Rectangle {
                id: badge
                width: 44
                height: 44
                radius: width / 2
                color: Qt.alpha(tile.accent, 0.16)

                DIcon {
                    anchors.centerIn: parent
                    name: tile.glyph
                    size: Theme.iconSize
                    color: tile.accent
                }
            }

            Column {
                anchors.left: badge.right
                anchors.leftMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: I18n.trFor("duxSkoda", "Climate")
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                }

                StyledText {
                    text: tile.statusText
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }

            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: tile.temp
                color: tile.accent
                font.pixelSize: Theme.fontSizeXLarge + 6
                font.weight: Font.Bold
            }
        }

        Item {
            visible: tile.info !== "" || tile.canAct
            width: parent.width
            height: Math.max(infoText.height, action.height)

            StyledText {
                id: infoText
                anchors.left: parent.left
                anchors.right: action.visible ? action.left : parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: tile.info
                color: tile.failure !== "" ? Theme.error : Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }

            LinkButton {
                id: action
                objectName: "acButton"
                visible: tile.canAct
                anchors.right: parent.right
                text: tile.on ? I18n.trFor("duxSkoda", "Stop") : I18n.trFor("duxSkoda", "Start")
                onClicked: tile.on ? tile.stop() : tile.start()
            }
        }
    }
}
