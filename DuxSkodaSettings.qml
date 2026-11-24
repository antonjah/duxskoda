import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "duxSkoda"

    StyledText {
        width: parent.width
        text: I18n.trFor("duxSkoda", "Create an API key in the MyŠkoda app (version 8.16 or newer; go.skoda.eu/api-keys opens key management on your phone). Put the key alone in a file and your VIN alone in another, and point to them below. The key itself is never stored in these settings.")
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("duxSkoda", "Values set in ~/.config/skoda/config.json (for example by home-manager) override the settings below.")
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "tokenFile"
        label: I18n.trFor("duxSkoda", "API key file")
        description: I18n.trFor("duxSkoda", "Path to a file containing only your MyŠkoda API key")
        placeholder: "~/.config/skoda/token"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "vinFile"
        label: I18n.trFor("duxSkoda", "VIN file")
        description: I18n.trFor("duxSkoda", "Path to a file containing only the 17 character VIN of your car")
        placeholder: "~/.config/skoda/vin"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "refreshMinutes"
        label: I18n.trFor("duxSkoda", "Refresh interval")
        description: I18n.trFor("duxSkoda", "How often to ask Škoda for the car's state. The limit is 20 requests per hour for your car, shared with every other app that uses it")
        options: [
            { label: "10 min", value: "10" },
            { label: "15 min", value: "15" },
            { label: "30 min", value: "30" },
            { label: "60 min", value: "60" }
        ]
        defaultValue: "15"
    }
}
