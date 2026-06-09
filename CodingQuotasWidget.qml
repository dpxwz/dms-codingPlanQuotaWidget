import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "coding-quotas"

    // Absolute path to the bundled fetcher (resolved relative to this file).
    readonly property string scriptPath: Qt.resolvedUrl("fetch.sh").toString().replace(/^file:\/\//, "")

    // Proc is a singleton that debounces by id; each widget instance (e.g. one
    // per monitor) needs its own id or they clobber each other's callbacks.
    readonly property string fetchId: "codingQuotas.fetch." + Math.floor(Math.random() * 1e9)

    property var qdata: ({
            ts: 0,
            providers: []
        })
    readonly property var providers: (qdata && qdata.providers) ? qdata.providers : []
    property bool loading: false
    property string lastError: ""

    readonly property int refreshSec: {
        const v = pluginData ? pluginData.refreshIntervalSec : undefined
        return (typeof v === "number" && v >= 30) ? v : 300
    }
    readonly property bool compactBar: pluginData ? (pluginData.compactBar === true) : false

    component ProviderIcon: Item {
        id: pi
        required property string providerId
        property int iconSize: Theme.fontSizeSmall + 4
        // Logos stay light on the dark bar; quota level color is on the % text only.
        property color tint: "#ffffff"

        readonly property string logoSource: {
            switch (providerId) {
            case "codex":
                return Qt.resolvedUrl("icons/codex.svg")
            case "cursor":
                return Qt.resolvedUrl("icons/cursor.svg")
            case "antigravity":
                return Qt.resolvedUrl("icons/antigravity.svg")
            case "deepseek":
                return Qt.resolvedUrl("icons/deepseek.svg")
            case "opencodeGo":
                return Qt.resolvedUrl("icons/opencode.svg")
            default:
                return ""
            }
        }

        implicitWidth: iconSize
        implicitHeight: iconSize

        // The SVGs are authored white-filled; render natively rather than via
        // MultiEffect colorization, which cannot lighten a black source.
        DankSVGIcon {
            visible: pi.logoSource !== ""
            anchors.centerIn: parent
            source: pi.logoSource
            size: pi.iconSize
        }

        DankIcon {
            visible: pi.logoSource === ""
            anchors.centerIn: parent
            name: "extension"
            size: pi.iconSize
            color: pi.tint
        }
    }

    function levelColor(level) {
        switch (level) {
        case "ok":
            return Theme.success
        case "warn":
            return Theme.warning
        case "crit":
            return Theme.error
        case "neutral":
            return Theme.primary
        default:
            return Theme.outline
        }
    }

    function fmtReset(ts) {
        if (!ts)
            return ""
        const d = ts - (Date.now() / 1000)
        if (d <= 0)
            return ""
        const day = Math.floor(d / 86400)
        const h = Math.floor((d % 86400) / 3600)
        const m = Math.floor((d % 3600) / 60)
        if (day > 0)
            return "resets " + day + "d " + h + "h"
        if (h > 0)
            return "resets " + h + "h " + m + "m"
        return "resets " + m + "m"
    }

    function fmtAge(ts) {
        if (!ts)
            return ""
        const d = Date.now() / 1000 - ts
        if (d < 60)
            return "updated just now"
        if (d < 3600)
            return "updated " + Math.floor(d / 60) + "m ago"
        if (d < 86400)
            return "updated " + Math.floor(d / 3600) + "h ago"
        return "updated " + Math.floor(d / 86400) + "d ago"
    }

    function refresh() {
        if (!scriptPath)
            return
        root.loading = true
        Proc.runCommand(root.fetchId, ["bash", root.scriptPath, "all"], function (out, code) {
            root.loading = false
            if (code === 0 && out && out.trim().length > 0) {
                try {
                    root.qdata = JSON.parse(out)
                    root.lastError = ""
                } catch (e) {
                    root.lastError = "parse error"
                }
            } else {
                root.lastError = "fetch failed (" + code + ")"
            }
        }, 50, 30000)
    }

    Component.onCompleted: refresh()

    Timer {
        interval: root.refreshSec * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // ---- Horizontal bar pill: a row of per-plan chips -----------------------
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            Repeater {
                model: root.providers
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    readonly property color lc: root.levelColor(modelData.level)
                    height: root.widgetThickness
                    width: chipContent.implicitWidth + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Qt.rgba(lc.r, lc.g, lc.b, 0.16)

                    Row {
                        id: chipContent
                        anchors.centerIn: parent
                        spacing: 3

                        ProviderIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            providerId: chip.modelData.id
                            iconSize: Theme.fontSizeSmall + 4
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !root.compactBar
                            text: chip.modelData.headlineText
                            color: chip.lc
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                        }
                    }

                    Rectangle {
                        visible: chip.modelData.stale === true
                        width: 6
                        height: 6
                        radius: 3
                        color: Theme.warning
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 2
                    }
                }
            }

            // Fallback so the widget stays clickable before data arrives.
            Rectangle {
                visible: root.providers.length === 0
                height: root.widgetThickness
                width: height
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                DankIcon {
                    anchors.centerIn: parent
                    name: "data_usage"
                    size: Theme.fontSizeSmall + 4
                    color: root.loading ? Theme.primary : Theme.surfaceVariantText
                }
            }
        }
    }

    // ---- Vertical bar pill: a compact column of icons -----------------------
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            Repeater {
                model: root.providers
                delegate: Column {
                    required property var modelData
                    readonly property color lc: root.levelColor(modelData.level)
                    spacing: 0
                    width: root.widgetThickness

                    ProviderIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        providerId: modelData.id
                        iconSize: Theme.fontSizeSmall + 4
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !root.compactBar && modelData.headlinePct !== null
                        text: (modelData.headlinePct !== null ? modelData.headlinePct + "" : "")
                        color: lc
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Medium
                    }
                }
            }

            Rectangle {
                visible: root.providers.length === 0
                width: root.widgetThickness
                height: width
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                DankIcon {
                    anchors.centerIn: parent
                    name: "data_usage"
                    size: Theme.fontSizeSmall + 4
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    // ---- Popout: detailed breakdown ----------------------------------------
    popoutWidth: 460
    popoutHeight: 560

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Coding Plan Quota"
            detailsText: root.lastError ? ("Error: " + root.lastError) : "Remaining quota & balance per plan"
            showCloseButton: true

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popout.headerHeight - popout.detailsHeight - Theme.spacingXL

                // Top row: last-updated + refresh button
                Item {
                    id: topRow
                    width: parent.width
                    height: 28

                    StyledText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.loading ? "refreshing…" : root.fmtAge(root.qdata ? root.qdata.ts : 0)
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    Rectangle {
                        id: refreshBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 28
                        height: 28
                        radius: Theme.cornerRadius
                        color: refreshArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        DankIcon {
                            anchors.centerIn: parent
                            name: "refresh"
                            size: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            NumberAnimation on rotation {
                                running: root.loading
                                from: 0
                                to: 360
                                duration: 900
                                loops: Animation.Infinite
                            }
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refresh()
                        }
                    }
                }

                DankFlickable {
                    anchors.top: topRow.bottom
                    anchors.topMargin: Theme.spacingS
                    width: parent.width
                    height: parent.height - topRow.height - Theme.spacingS
                    clip: true
                    contentHeight: cardColumn.height
                    boundsBehavior: Flickable.StopAtBounds
                    mouseWheelSpeed: 100

                    Column {
                        id: cardColumn
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.providers
                            delegate: Rectangle {
                                id: card
                                required property var modelData
                                readonly property color lc: root.levelColor(modelData.level)
                                width: cardColumn.width
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                height: cardCol.implicitHeight + Theme.spacingM * 2

                                Column {
                                    id: cardCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingXS

                                    // Header: icon + name + headline
                                    Item {
                                        width: parent.width
                                        height: 26

                                        Row {
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingXS

                                            Rectangle {
                                                width: 24
                                                height: 24
                                                radius: Theme.cornerRadius
                                                color: Qt.rgba(card.lc.r, card.lc.g, card.lc.b, 0.18)
                                                anchors.verticalCenter: parent.verticalCenter
                                                ProviderIcon {
                                                    anchors.centerIn: parent
                                                    providerId: card.modelData.id
                                                    iconSize: Theme.fontSizeMedium
                                                }
                                            }

                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: card.modelData.name
                                                color: Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.DemiBold
                                            }

                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: card.modelData.sub && card.modelData.sub.length > 0
                                                text: card.modelData.sub
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                            }

                                            Rectangle {
                                                visible: card.modelData.stale === true
                                                anchors.verticalCenter: parent.verticalCenter
                                                radius: 4
                                                color: Qt.rgba(Theme.warning.r, Theme.warning.g, Theme.warning.b, 0.2)
                                                width: staleText.implicitWidth + 10
                                                height: 16
                                                StyledText {
                                                    id: staleText
                                                    anchors.centerIn: parent
                                                    text: "stale"
                                                    color: Theme.warning
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                }
                                            }
                                        }

                                        StyledText {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: card.modelData.headlineText
                                            color: card.lc
                                            font.pixelSize: Theme.fontSizeLarge
                                            font.weight: Font.Bold
                                        }
                                    }

                                    // Error / hint
                                    StyledText {
                                        visible: !card.modelData.ok
                                        width: parent.width
                                        text: card.modelData.error || "unavailable"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                        wrapMode: Text.WordWrap
                                    }

                                    // Quota windows
                                    Repeater {
                                        model: card.modelData.windows || []
                                        delegate: Column {
                                            required property var modelData
                                            width: cardCol.width
                                            spacing: 2

                                            Item {
                                                width: parent.width
                                                height: 16
                                                StyledText {
                                                    anchors.left: parent.left
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.label
                                                    color: Theme.surfaceText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    width: parent.width * 0.55
                                                    elide: Text.ElideRight
                                                }
                                                StyledText {
                                                    anchors.right: parent.right
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: {
                                                        var parts = []
                                                        if (modelData.remainingPct !== null && modelData.remainingPct !== undefined)
                                                            parts.push(modelData.remainingPct + "%")
                                                        var r = root.fmtReset(modelData.resetAt)
                                                        if (r)
                                                            parts.push(r)
                                                        return parts.join("  ·  ")
                                                    }
                                                    color: Theme.surfaceVariantText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                }
                                            }

                                            // progress bar (only when a percentage exists)
                                            Rectangle {
                                                visible: modelData.remainingPct !== null && modelData.remainingPct !== undefined
                                                width: parent.width
                                                height: 6
                                                radius: 3
                                                color: Theme.surfaceContainerHighest
                                                Rectangle {
                                                    width: parent.width * Math.max(0, Math.min(1, (modelData.remainingPct || 0) / 100))
                                                    height: parent.height
                                                    radius: 3
                                                    color: card.lc
                                                }
                                            }

                                            StyledText {
                                                visible: modelData.detail && modelData.detail.length > 0
                                                width: parent.width
                                                text: modelData.detail || ""
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
