import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "codingQuotas"

    StyledText {
        width: parent.width
        text: "Coding Plan Quotas"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Track remaining quota / balance for each coding plan. Codex, Cursor and Antigravity are read automatically from local sessions/credentials. DeepSeek needs an API key; OpenCode Go needs your opencode.ai login cookie. Secrets are stored locally in plugin_settings.json."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ---- Which plans to show -------------------------------------------------
    StyledText {
        width: parent.width
        text: "Plans"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.DemiBold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "enableCodex"
        label: "Codex"
        description: "OpenAI Codex CLI — 5h & weekly limits (read from ~/.codex sessions)"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "enableHermes"
        label: "Hermes"
        description: "Hermes Agent Token Tracker — daily & 30d usage (read from ~/.hermes sessions)"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "enableCursor"
        label: "Cursor"
        description: "Cursor included-plan usage (read from the Cursor app session)"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "enableAntigravity"
        label: "Antigravity"
        description: "Google Antigravity per-model quota (requires the IDE running)"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "enableDeepseek"
        label: "DeepSeek"
        description: "DeepSeek platform account balance (requires API key below)"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "enableOpencodeGo"
        label: "OpenCode Go"
        description: "OpenCode Zen Go plan usage (requires opencode.ai cookie below)"
        defaultValue: true
    }

    // ---- Credentials ---------------------------------------------------------
    StyledText {
        width: parent.width
        text: "Credentials"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.DemiBold
        color: Theme.surfaceText
    }

    StringSetting {
        settingKey: "deepseekApiKey"
        label: "DeepSeek API key"
        description: "From platform.deepseek.com → API keys. Used only for GET /user/balance."
        placeholder: "sk-..."
        defaultValue: ""
    }

    StringSetting {
        settingKey: "opencodeCookie"
        label: "OpenCode.ai cookie"
        description: "The auth cookie from opencode.ai (DevTools → Application → Cookies). Paste the value or a full 'name=value' string."
        placeholder: "auth=..."
        defaultValue: ""
    }

    StringSetting {
        settingKey: "opencodeWorkspaceId"
        label: "OpenCode workspace ID"
        description: "Required. Open your Zen dashboard and copy the ID from the URL: opencode.ai/workspace/<ID>/go"
        placeholder: "wrk_..."
        defaultValue: ""
    }

    // ---- Display -------------------------------------------------------------
    StyledText {
        width: parent.width
        text: "Display"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.DemiBold
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "compactBar"
        label: "Compact bar (icons only)"
        description: "Hide the numbers in the bar and show colored icons only. Full details remain in the popout."
        defaultValue: false
    }

    SliderSetting {
        settingKey: "refreshIntervalSec"
        label: "Refresh interval"
        description: "How often to refresh quota data"
        defaultValue: 300
        minimum: 30
        maximum: 1800
        unit: "s"
        leftIcon: "schedule"
    }
}
