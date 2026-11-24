import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import "Skoda.js" as Skoda

Rectangle {
    id: tile

    property var m: null
    property color accent: Theme.primary
    property real now: Date.now()

    readonly property string title: !m ? "" : m.name.toLowerCase().indexOf("škoda") >= 0 ? m.name : "Škoda " + m.name
    readonly property string status: {
        switch (m ? m.status : "") {
        case "charging": return I18n.trFor("duxSkoda", "Charging")
        case "interrupted": return I18n.trFor("duxSkoda", "Charging interrupted")
        case "plugged": return I18n.trFor("duxSkoda", "Plugged in")
        case "unplugged": return I18n.trFor("duxSkoda", "Not plugged in")
        default: return ""
        }
    }
    readonly property string statusIcon: !m ? "" : m.charging ? "bolt" : m.status === "plugged" || m.status === "interrupted" ? "power" : "power_off"

    implicitHeight: body.height + Theme.spacingL * 2
    radius: Theme.cornerRadius * 1.5
    color: Theme.surfaceContainerHigh

    function seen() {
        if (!m || !m.seenAt)
            return ""
        const days = Skoda.daysAgo(m.seenAt, now)
        const at = Qt.formatTime(new Date(m.seenAt), "HH:mm")
        return days <= 0 ? I18n.trFor("duxSkoda", "Seen %1").arg(at) : days === 1 ? I18n.trFor("duxSkoda", "Seen yesterday %1").arg(at) : I18n.trFor("duxSkoda", "Seen %1 days ago").arg(days)
    }

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
                    name: "electric_car"
                    size: Theme.iconSize
                    color: tile.accent
                }
            }

            Column {
                anchors.left: badge.right
                anchors.leftMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: tile.title
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                }

                Row {
                    spacing: Theme.spacingXS

                    DIcon {
                        name: tile.statusIcon
                        size: Theme.fontSizeSmall
                        color: tile.accent
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: tile.status
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: tile.m && tile.m.soc !== null ? tile.m.soc + " %" : "–"
                color: tile.accent
                font.pixelSize: Theme.fontSizeXLarge + 6
                font.weight: Font.Bold
            }
        }

        Item {
            width: parent.width
            height: 14

            Rectangle {
                id: track
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 8
                radius: height / 2
                color: Qt.alpha(Theme.surfaceText, 0.12)

                Rectangle {
                    width: tile.m && tile.m.soc !== null ? track.width * Math.min(100, tile.m.soc) / 100 : 0
                    height: parent.height
                    radius: height / 2
                    color: tile.accent
                }
            }

            Rectangle {
                visible: !!tile.m && tile.m.target !== null && tile.m.target > 0
                x: tile.m && tile.m.target !== null ? track.width * tile.m.target / 100 - 1 : 0
                anchors.verticalCenter: parent.verticalCenter
                width: 2
                height: 14
                radius: 1
                color: Qt.alpha(Theme.surfaceText, 0.8)
            }
        }

        Item {
            width: parent.width
            height: rangeText.height

            StyledText {
                id: rangeText
                text: tile.m && tile.m.rangeKm !== null ? I18n.trFor("duxSkoda", "%1 km range").arg(tile.m.rangeKm) : ""
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
            }

            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !!tile.m && tile.m.target !== null
                text: tile.m && tile.m.target !== null ? I18n.trFor("duxSkoda", "Target %1 %").arg(tile.m.target) : ""
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        StyledText {
            visible: text !== ""
            text: tile.seen()
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
    }
}
