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

    readonly property var codexProvider: {
        for (var i = 0; i < providers.length; i++) {
            if (providers[i].id === "codex") {
                return providers[i];
            }
        }
        return null;
    }

    readonly property int maxHistoryVal: {
        if (!codexProvider || !codexProvider.tokenTracker || !codexProvider.tokenTracker.history)
            return 1;
        var max = 0;
        var hist = codexProvider.tokenTracker.history;
        for (var i = 0; i < hist.length; i++) {
            if (hist[i].total > max) {
                max = hist[i].total;
            }
        }
        return max > 0 ? max : 1;
    }

    function fmtTokens(n) {
        if (n === undefined || n === null) return "0"
        if (n >= 1000000) {
            return (n / 1000000).toFixed(1) + "M"
        }
        if (n >= 1000) {
            return (n / 1000).toFixed(1) + "K"
        }
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    }

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
    popoutWidth: 800
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

                Row {
                    id: mainRow
                    anchors.top: topRow.bottom
                    anchors.topMargin: Theme.spacingS
                    anchors.bottom: parent.bottom
                    width: parent.width
                    spacing: Theme.spacingM

                    DankFlickable {
                        width: 440
                        height: parent.height
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

                    // Right Side: Codex Token Tracker Panel
                    Rectangle {
                        id: tokenTrackerCard
                        width: parent.width - 440 - Theme.spacingM
                        height: parent.height
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        property var hoveredBarData: null

                        readonly property var todayTokens: (root.codexProvider && root.codexProvider.tokenTracker && root.codexProvider.tokenTracker.today) ? root.codexProvider.tokenTracker.today : null
                        readonly property int todayTotal: todayTokens ? todayTokens.total : 0
                        readonly property int todayCached: todayTokens ? todayTokens.cached : 0
                        readonly property int todayActiveInput: todayTokens ? (todayTokens.input - todayTokens.cached) : 0
                        readonly property int todayOutput: todayTokens ? todayTokens.output : 0
                        readonly property int todayReasoning: todayTokens ? todayTokens.reasoning : 0

                        readonly property color colorCached: "#00b4d8"
                        readonly property color colorActiveInput: "#90e0ef"
                        readonly property color colorOutput: "#ffb703"
                        readonly property color colorReasoning: "#fb8500"

                        StyledText {
                            visible: !root.codexProvider
                            anchors.centerIn: parent
                            text: "Codex is not enabled in settings"
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        Column {
                            visible: root.codexProvider !== null
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS
                                DankIcon {
                                    name: "query_stats"
                                    size: Theme.fontSizeMedium
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: "Codex Token Tracker"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                width: parent.width
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                text: {
                                    if (tokenTrackerCard.hoveredBarData) {
                                        return "History (" + tokenTrackerCard.hoveredBarData.date + "): " + root.fmtTokens(tokenTrackerCard.hoveredBarData.total) + " tokens"
                                    } else {
                                        var todayDate = (root.codexProvider && root.codexProvider.tokenTracker && root.codexProvider.tokenTracker.history && root.codexProvider.tokenTracker.history.length > 0) ? root.codexProvider.tokenTracker.history[0].date : ""
                                        var todayVal = (root.codexProvider && root.codexProvider.tokenTracker && root.codexProvider.tokenTracker.today) ? root.codexProvider.tokenTracker.today.total : 0
                                        return "Today (" + todayDate + "): " + root.fmtTokens(todayVal) + " tokens"
                                    }
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 140
                                color: Theme.surfaceContainerHighest
                                radius: Theme.cornerRadius

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: 3
                                    anchors.bottom: parent.bottom

                                    Repeater {
                                        model: {
                                            if (!root.codexProvider || !root.codexProvider.tokenTracker || !root.codexProvider.tokenTracker.history)
                                                return [];
                                            var list = root.codexProvider.tokenTracker.history.slice();
                                            list.reverse();
                                            return list;
                                        }

                                        delegate: Item {
                                            id: barCol
                                            height: parent.height
                                            width: (parent.width - (29 * 3) - (Theme.spacingS * 2)) / 30

                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                width: parent.width
                                                height: {
                                                    if (!root.maxHistoryVal) return 2;
                                                    var pct = modelData.total / root.maxHistoryVal;
                                                    return Math.max(2, pct * (parent.height - Theme.spacingS));
                                                }
                                                radius: 2
                                                color: {
                                                    var isHovered = (tokenTrackerCard.hoveredBarData && tokenTrackerCard.hoveredBarData.date === modelData.date)
                                                    var isToday = (index === 29)
                                                    if (isHovered) return Theme.primary
                                                    if (isToday) return Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.9)
                                                    return Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.4)
                                                }

                                                Behavior on height {
                                                    NumberAnimation { duration: 350; easing.type: Easing.OutQuad }
                                                }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                onEntered: tokenTrackerCard.hoveredBarData = modelData
                                                onExited: {
                                                    if (tokenTrackerCard.hoveredBarData === modelData) {
                                                        tokenTrackerCard.hoveredBarData = null;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Divider
                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outline
                                opacity: 0.2
                            }

                            // Segmented Ratio Bar
                            Item {
                                width: parent.width
                                height: 10

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 3
                                    color: Theme.surfaceContainerHighest
                                    visible: tokenTrackerCard.todayTotal === 0
                                }

                                Row {
                                    anchors.fill: parent
                                    spacing: 2
                                    visible: tokenTrackerCard.todayTotal > 0

                                    Rectangle {
                                        height: parent.height
                                        width: {
                                            if (tokenTrackerCard.todayTotal === 0) return 0;
                                            var w = parent.width * (tokenTrackerCard.todayCached / tokenTrackerCard.todayTotal);
                                            return Math.max(0, w - 1);
                                        }
                                        radius: 3
                                        color: tokenTrackerCard.colorCached
                                    }

                                    Rectangle {
                                        height: parent.height
                                        width: {
                                            if (tokenTrackerCard.todayTotal === 0) return 0;
                                            var w = parent.width * (tokenTrackerCard.todayActiveInput / tokenTrackerCard.todayTotal);
                                            return Math.max(0, w - 1);
                                        }
                                        radius: 3
                                        color: tokenTrackerCard.colorActiveInput
                                    }

                                    Rectangle {
                                        height: parent.height
                                        width: {
                                            if (tokenTrackerCard.todayTotal === 0) return 0;
                                            var w = parent.width * (tokenTrackerCard.todayOutput / tokenTrackerCard.todayTotal);
                                            return Math.max(0, w - 1);
                                        }
                                        radius: 3
                                        color: tokenTrackerCard.colorOutput
                                    }
                                }
                            }

                            // Detailed rows
                            Column {
                                width: parent.width
                                spacing: Theme.spacingXS

                                component BreakdownRow: Item {
                                    id: br
                                    required property string label
                                    required property int count
                                    required property color colorDot
                                    property bool isSubset: false
                                    width: parent.width
                                    height: 20

                                    Row {
                                        anchors.left: parent.left
                                        anchors.leftMargin: br.isSubset ? Theme.spacingM : 0
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS

                                        Rectangle {
                                            width: br.isSubset ? 6 : 8
                                            height: width
                                            radius: width / 2
                                            color: br.colorDot
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: br.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: br.isSubset ? Theme.surfaceVariantText : Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: root.fmtTokens(br.count)
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            visible: !br.isSubset && tokenTrackerCard.todayTotal > 0
                                            text: Math.round((br.count / tokenTrackerCard.todayTotal) * 100) + "%"
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 32
                                            horizontalAlignment: Text.AlignRight
                                        }
                                    }
                                }

                                BreakdownRow {
                                    label: "Cached Input"
                                    count: tokenTrackerCard.todayCached
                                    colorDot: tokenTrackerCard.colorCached
                                }

                                BreakdownRow {
                                    label: "Active Input"
                                    count: tokenTrackerCard.todayActiveInput
                                    colorDot: tokenTrackerCard.colorActiveInput
                                }

                                BreakdownRow {
                                    label: "Output"
                                    count: tokenTrackerCard.todayOutput
                                    colorDot: tokenTrackerCard.colorOutput
                                }

                                BreakdownRow {
                                    label: "Reasoning"
                                    count: tokenTrackerCard.todayReasoning
                                    colorDot: tokenTrackerCard.colorReasoning
                                    isSubset: true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
