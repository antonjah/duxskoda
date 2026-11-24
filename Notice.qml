import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets

// A tinted message card: errors, setup steps and warnings.
Rectangle {
    id: notice

    property string icon: "error"
    property string title
    property string text
    property color tint: Theme.error
    property color textColor: Theme.surfaceText

    implicitHeight: body.height + Theme.spacingM * 2
    radius: Theme.cornerRadius
    color: Qt.alpha(tint, 0.14)

    Row {
        id: body
        x: Theme.spacingM
        y: Theme.spacingM
        width: parent.width - Theme.spacingM * 2
        spacing: Theme.spacingS

        DIcon {
            name: notice.icon
            size: Theme.iconSize
            color: notice.tint
        }

        Column {
            width: parent.width - Theme.iconSize - Theme.spacingS
            spacing: Theme.spacingXS

            StyledText {
                visible: notice.title !== ""
                width: parent.width
                text: notice.title
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                wrapMode: Text.WordWrap
            }

            StyledText {
                width: parent.width
                text: notice.text
                color: notice.textColor
                font.pixelSize: notice.title !== "" ? Theme.fontSizeSmall : Theme.fontSizeMedium
                wrapMode: Text.WordWrap
            }
        }
    }
}
