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

    readonly property bool enableHermesSetting: pluginData ? (pluginData.enableHermes !== false) : true
    readonly property bool showHermesTracker: enableHermesSetting && root.qdata && root.qdata.hermes !== null && root.qdata.hermes !== undefined

    readonly property int maxHermesHistoryVal: {
        if (!root.qdata || !root.qdata.hermes || !root.qdata.hermes.history)
            return 1;
        var max = 0;
        var hist = root.qdata.hermes.history;
        for (var i = 0; i < hist.length; i++) {
            if (hist[i].total > max) {
                max = hist[i].total;
            }
        }
        return max > 0 ? max : 1;
    }

    readonly property int codex30dTotal: {
        if (!codexProvider || !codexProvider.tokenTracker || !codexProvider.tokenTracker.history)
            return 0;
        var sum = 0;
        var hist = codexProvider.tokenTracker.history;
        for (var i = 0; i < hist.length; i++) {
            sum += hist[i].total;
        }
        return sum;
    }

    readonly property int hermes30dTotal: {
        if (!root.qdata || !root.qdata.hermes || !root.qdata.hermes.history)
            return 0;
        var sum = 0;
        var hist = root.qdata.hermes.history;
        for (var i = 0; i < hist.length; i++) {
            sum += hist[i].total;
        }
        return sum;
    }

    readonly property var hermes30dModels: {
        if (!root.qdata || !root.qdata.hermes || !root.qdata.hermes.history)
            return [];
        var modelMap = {};
        var hist = root.qdata.hermes.history;
        for (var i = 0; i < hist.length; i++) {
            var models = hist[i].models || [];
            for (var j = 0; j < models.length; j++) {
                var name = models[j].model;
                var tokens = models[j].tokens || 0;
                if (modelMap[name] !== undefined) {
                    modelMap[name] += tokens;
                } else {
                    modelMap[name] = tokens;
                }
            }
        }
        var result = [];
        for (var key in modelMap) {
            result.push({ "model": key, "tokens": modelMap[key] });
        }
        result.sort(function(a, b) { return b.tokens - a.tokens; });
        return result;
    }

    function getModelColor(model) {
        if (!model) return "#94a3b8";
        var m = model.toLowerCase();
        if (m.indexOf("gpt-5.4") !== -1) return "#00a676";
        if (m.indexOf("gpt-5.5") !== -1) return "#10a37f";
        if (m.indexOf("gpt") !== -1 || m.indexOf("openai") !== -1) return "#0fa47f";
        if (m.indexOf("deepseek-v4-pro") !== -1) return "#2563eb";
        if (m.indexOf("deepseek-v4-flash") !== -1) return "#60a5fa";
        if (m.indexOf("deepseek") !== -1) return "#3b82f6";
        if (m.indexOf("glm") !== -1) return "#a855f7";
        if (m.indexOf("kimi") !== -1) return "#ea580c";
        if (m.indexOf("minimax") !== -1) return "#ec4899";
        if (m.indexOf("claude") !== -1) return "#d97706";
        if (m.indexOf("qwen") !== -1) return "#6366f1";
        return "#64748b"; // default slate
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
    popoutHeight: 860

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

                    // Right Side: Token Tracker Panel(s)
                    Column {
                        id: tokenTrackersCol
                        width: parent.width - 440 - Theme.spacingM
                        height: parent.height
                        spacing: Theme.spacingM

                        readonly property bool showCodex: root.codexProvider !== null
                        readonly property bool showHermes: root.showHermesTracker

                        // Codex Token Tracker Card
                        Rectangle {
                            id: codexTrackerCard
                            width: parent.width
                            visible: tokenTrackersCol.showCodex
                            height: {
                                if (tokenTrackersCol.showCodex && tokenTrackersCol.showHermes) {
                                    return (parent.height - Theme.spacingM) / 2;
                                }
                                return parent.height;
                            }
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

                            Column {
                                anchors.fill: parent
                                anchors.margins: parent.height > 400 ? Theme.spacingM : Theme.spacingS
                                spacing: parent.height > 400 ? Theme.spacingS : 2

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

                                Rectangle {
                                    width: parent.width
                                    height: codexTrackerCard.height > 400 ? 140 : 80
                                    color: Theme.surfaceContainerHighest
                                    radius: Theme.cornerRadius

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingS
                                        spacing: 0
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
                                                width: (parent.width - (Theme.spacingS * 2)) / 30

                                                Rectangle {
                                                    anchors.bottom: parent.bottom
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    width: Math.max(1, parent.width - 3)
                                                    height: {
                                                        if (!root.maxHistoryVal) return 2;
                                                        var pct = modelData.total / root.maxHistoryVal;
                                                        return Math.max(2, pct * (parent.height - Theme.spacingS));
                                                    }
                                                    radius: 2
                                                    color: {
                                                        var isHovered = (codexTrackerCard.hoveredBarData && codexTrackerCard.hoveredBarData.date === modelData.date)
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
                                                    onEntered: codexTrackerCard.hoveredBarData = modelData
                                                    onExited: {
                                                        if (codexTrackerCard.hoveredBarData && codexTrackerCard.hoveredBarData.date === modelData.date) {
                                                            codexTrackerCard.hoveredBarData = null;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    text: {
                                        if (codexTrackerCard.hoveredBarData) {
                                            return "History (" + codexTrackerCard.hoveredBarData.date + "): " + root.fmtTokens(codexTrackerCard.hoveredBarData.total) + " tokens"
                                        } else {
                                            var todayDate = (root.codexProvider && root.codexProvider.tokenTracker && root.codexProvider.tokenTracker.history && root.codexProvider.tokenTracker.history.length > 0) ? root.codexProvider.tokenTracker.history[0].date : ""
                                            return "Today (" + todayDate + "): " + root.fmtTokens(codexTrackerCard.todayTotal) + "\nPast 30 Days: " + root.fmtTokens(root.codex30dTotal)
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
                                        visible: codexTrackerCard.todayTotal === 0
                                    }

                                    Row {
                                        anchors.fill: parent
                                        spacing: 2
                                        visible: codexTrackerCard.todayTotal > 0

                                        Rectangle {
                                            height: parent.height
                                            width: {
                                                if (codexTrackerCard.todayTotal === 0) return 0;
                                                var w = parent.width * (codexTrackerCard.todayCached / codexTrackerCard.todayTotal);
                                                return Math.max(0, w - 1);
                                            }
                                            radius: 3
                                            color: codexTrackerCard.colorCached
                                        }

                                        Rectangle {
                                            height: parent.height
                                            width: {
                                                if (codexTrackerCard.todayTotal === 0) return 0;
                                                var w = parent.width * (codexTrackerCard.todayActiveInput / codexTrackerCard.todayTotal);
                                                return Math.max(0, w - 1);
                                            }
                                            radius: 3
                                            color: codexTrackerCard.colorActiveInput
                                        }

                                        Rectangle {
                                            height: parent.height
                                            width: {
                                                if (codexTrackerCard.todayTotal === 0) return 0;
                                                var w = parent.width * (codexTrackerCard.todayOutput / codexTrackerCard.todayTotal);
                                                return Math.max(0, w - 1);
                                            }
                                            radius: 3
                                            color: codexTrackerCard.colorOutput
                                        }
                                    }
                                }

                                // Detailed rows
                                Column {
                                    width: parent.width
                                    spacing: codexTrackerCard.height > 400 ? Theme.spacingXS : 1

                                    component BreakdownRow: Item {
                                        id: br
                                        required property string label
                                        required property int count
                                        required property color colorDot
                                        property bool isSubset: false
                                        width: parent.width
                                        height: codexTrackerCard.height > 400 ? 20 : 15

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
                                                font.pixelSize: codexTrackerCard.height > 400 ? Theme.fontSizeSmall : Theme.fontSizeSmall - 1
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
                                                font.pixelSize: codexTrackerCard.height > 400 ? Theme.fontSizeSmall : Theme.fontSizeSmall - 1
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            StyledText {
                                                visible: !br.isSubset && codexTrackerCard.todayTotal > 0
                                                text: Math.round((br.count / codexTrackerCard.todayTotal) * 100) + "%"
                                                font.pixelSize: codexTrackerCard.height > 400 ? Theme.fontSizeSmall - 1 : Theme.fontSizeSmall - 2
                                                color: Theme.surfaceVariantText
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 32
                                                horizontalAlignment: Text.AlignRight
                                            }
                                        }
                                    }

                                    BreakdownRow {
                                        label: "Cached Input"
                                        count: codexTrackerCard.todayCached
                                        colorDot: codexTrackerCard.colorCached
                                    }

                                    BreakdownRow {
                                        label: "Active Input"
                                        count: codexTrackerCard.todayActiveInput
                                        colorDot: codexTrackerCard.colorActiveInput
                                    }

                                    BreakdownRow {
                                        label: "Output"
                                        count: codexTrackerCard.todayOutput
                                        colorDot: codexTrackerCard.colorOutput
                                    }

                                    BreakdownRow {
                                        label: "Reasoning"
                                        count: codexTrackerCard.todayReasoning
                                        colorDot: codexTrackerCard.colorReasoning
                                        isSubset: true
                                    }
                                }
                            }
                        }

                        // Hermes Token Tracker Card
                        Rectangle {
                            id: hermesTrackerCard
                            width: parent.width
                            visible: tokenTrackersCol.showHermes
                            height: {
                                if (tokenTrackersCol.showCodex && tokenTrackersCol.showHermes) {
                                    return (parent.height - Theme.spacingM) / 2;
                                }
                                return parent.height;
                            }
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            property var hoveredBarData: null

                            readonly property var hermesData: (root.qdata && root.qdata.hermes) ? root.qdata.hermes : null
                            readonly property var todayData: (hermesData && hermesData.history && hermesData.history.length > 0) ? hermesData.history[0] : null
                            readonly property int activeDayTotal: hoveredBarData ? hoveredBarData.total : root.hermes30dTotal

                            Column {
                                anchors.fill: parent
                                anchors.margins: parent.height > 400 ? Theme.spacingM : Theme.spacingS
                                spacing: parent.height > 400 ? Theme.spacingS : 2

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingXS
                                    DankIcon {
                                        name: "psychology"
                                        size: Theme.fontSizeMedium
                                        color: Theme.primary
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    StyledText {
                                        text: "Hermes Token Tracker"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: hermesTrackerCard.height > 400 ? 140 : 80
                                    color: Theme.surfaceContainerHighest
                                    radius: Theme.cornerRadius

                                    Row {
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingS
                                        spacing: 0
                                        anchors.bottom: parent.bottom

                                        Repeater {
                                            model: {
                                                if (!hermesTrackerCard.hermesData || !hermesTrackerCard.hermesData.history)
                                                    return [];
                                                var list = hermesTrackerCard.hermesData.history.slice();
                                                list.reverse();
                                                return list;
                                            }

                                            delegate: Item {
                                                id: barCol
                                                height: parent.height
                                                width: (parent.width - (Theme.spacingS * 2)) / 30

                                                // Stacked columns for each model
                                                Column {
                                                    anchors.bottom: parent.bottom
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    width: Math.max(1, parent.width - 3)
                                                    spacing: 0

                                                    Repeater {
                                                        model: {
                                                            var mList = modelData.models ? modelData.models.slice() : [];
                                                            // sort by token desc to have consistent visual layering
                                                            mList.sort(function(a, b) { return b.tokens - a.tokens; });
                                                            return mList;
                                                        }
                                                        delegate: Rectangle {
                                                            width: parent.width
                                                            height: {
                                                                if (!root.maxHermesHistoryVal) return 0;
                                                                var pct = modelData.tokens / root.maxHermesHistoryVal;
                                                                // scale height based on the container height (offset for margins)
                                                                var val = pct * (barCol.height - Theme.spacingS);
                                                                return Math.max(1, val);
                                                            }
                                                            color: {
                                                                var baseColor = root.getModelColor(modelData.model);
                                                                var isHovered = (hermesTrackerCard.hoveredBarData && hermesTrackerCard.hoveredBarData.date === modelData.date);
                                                                var isToday = (index === 29);
                                                                var c = Qt.color(baseColor);
                                                                if (isHovered) return c;
                                                                if (isToday) return Qt.rgba(c.r, c.g, c.b, 0.9);
                                                                return Qt.rgba(c.r, c.g, c.b, 0.5);
                                                            }
                                                        }
                                                    }
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    onEntered: hermesTrackerCard.hoveredBarData = modelData
                                                    onExited: {
                                                        if (hermesTrackerCard.hoveredBarData && hermesTrackerCard.hoveredBarData.date === modelData.date) {
                                                            hermesTrackerCard.hoveredBarData = null;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    text: {
                                        if (hermesTrackerCard.hoveredBarData) {
                                            return "History (" + hermesTrackerCard.hoveredBarData.date + "): " + root.fmtTokens(hermesTrackerCard.hoveredBarData.total) + " tokens";
                                        } else {
                                            var todayVal = hermesTrackerCard.todayData ? hermesTrackerCard.todayData.total : 0;
                                            var todayDate = hermesTrackerCard.todayData ? hermesTrackerCard.todayData.date : "";
                                            return "Today (" + todayDate + "): " + root.fmtTokens(todayVal) + "\nPast 30 Days: " + root.fmtTokens(root.hermes30dTotal);
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

                                // Legend / Detailed rows of active day models
                                DankFlickable {
                                    width: parent.width
                                    height: hermesTrackerCard.height > 400 ? 110 : 70
                                    clip: true
                                    contentHeight: legendCol.implicitHeight
                                    boundsBehavior: Flickable.StopAtBounds
                                    mouseWheelSpeed: 100

                                    Column {
                                        id: legendCol
                                        width: parent.width
                                        spacing: hermesTrackerCard.height > 400 ? Theme.spacingXS : 1

                                        Repeater {
                                            model: {
                                                var dayData = hermesTrackerCard.hoveredBarData ? hermesTrackerCard.hoveredBarData : hermesTrackerCard.todayData;
                                                if (!dayData || !dayData.models)
                                                    return [];
                                                var mList = dayData.models.slice();
                                                mList.sort(function(a, b) { return b.tokens - a.tokens; });
                                                return mList;
                                            }

                                            delegate: Item {
                                                required property var modelData
                                                width: legendCol.width
                                                height: hermesTrackerCard.height > 400 ? 20 : 15

                                                Row {
                                                    anchors.left: parent.left
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: Theme.spacingXS

                                                    Rectangle {
                                                        width: 8
                                                        height: width
                                                        radius: width / 2
                                                        color: root.getModelColor(modelData.model)
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }

                                                    StyledText {
                                                        text: modelData.model
                                                        font.pixelSize: hermesTrackerCard.height > 400 ? Theme.fontSizeSmall : Theme.fontSizeSmall - 1
                                                        color: Theme.surfaceText
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }
                                                }

                                                Row {
                                                    anchors.right: parent.right
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: Theme.spacingS

                                                    StyledText {
                                                        text: root.fmtTokens(modelData.tokens)
                                                        font.pixelSize: hermesTrackerCard.height > 400 ? Theme.fontSizeSmall : Theme.fontSizeSmall - 1
                                                        font.weight: Font.Medium
                                                        color: Theme.surfaceText
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }

                                                    StyledText {
                                                        visible: hermesTrackerCard.activeDayTotal > 0
                                                        text: Math.round((modelData.tokens / hermesTrackerCard.activeDayTotal) * 100) + "%"
                                                        font.pixelSize: hermesTrackerCard.height > 400 ? Theme.fontSizeSmall - 1 : Theme.fontSizeSmall - 2
                                                        color: Theme.surfaceVariantText
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: 32
                                                        horizontalAlignment: Text.AlignRight
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Placeholder when neither is enabled
                        Rectangle {
                            width: parent.width
                            height: parent.height
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            visible: !tokenTrackersCol.showCodex && !tokenTrackersCol.showHermes

                            StyledText {
                                anchors.centerIn: parent
                                text: "No token trackers enabled"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeMedium
                            }
                        }
                    }
                }
            }
        }
    }
}
