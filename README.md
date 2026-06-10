<div align="center">

# ⚡ CodingQuotas

**A DankMaterialShell widget that tracks remaining quotas & balances across your AI coding plans — all in one glance.**

[![DMS Plugin](https://img.shields.io/badge/DMS-plugin-blueviolet?style=flat-square)](https://github.com/niccolofant/DankMaterialShell)
[![Shell: Bash](https://img.shields.io/badge/fetcher-bash-orange?style=flat-square)](#architecture)
[![QML](https://img.shields.io/badge/UI-QML%20%2F%20Qt6-blue?style=flat-square)](#architecture)

</div>

---

## Supported Providers

| Provider | Source | Auth | Metric |
|---|---|---|---|
| **Codex** (OpenAI CLI) | Local session files (`~/.codex/sessions`) | Automatic | 5-hour & weekly remaining % |
| **Cursor** | Local Cursor app DB + API call | Automatic | Auto & API remaining % |
| **Antigravity** (Google) | Language-server probe (local loopback) | Automatic | Per-model remaining % |
| **OpenCode Go** | Dashboard scraping (`opencode.ai`) | Cookie | 5h / Weekly / Monthly remaining % |
| **DeepSeek** | REST API (`/user/balance`) | API key | Account balance (¥ / $) |
| **Hermes** *(tracker only)* | Local SQLite DB (`~/.hermes/state.db`) | Automatic | 30-day token usage by model |

## Features

### 🎯 Bar Widget
A compact row of color-coded chips lives in your DankMaterialShell bar. Each chip shows a provider logo and its remaining quota percentage. Colors shift from **green → amber → red** as quotas deplete.

- **Compact mode** — show icons only, hide the numbers
- **Per-provider metric selection** — click a specific quota window (e.g. "5h" vs "Weekly") to control which metric the bar chip displays

### 📊 Popout Panel
Click the widget to open a detailed breakdown:

- **Quota cards** for every provider with labeled progress bars, reset countdowns, and plan tier badges
- **Token tracker charts** — interactive 30-day bar charts for Codex and Hermes showing daily token consumption
- **Token breakdown** — segmented ratio bar (cached input / active input / output / reasoning) with exact counts
- **Hermes model breakdown** — stacked colored bars per model (GPT, DeepSeek, Claude, Qwen, …) with a dynamic legend
- **Hover tooltips** — hover any bar in the chart to inspect that day's stats
- **One-click refresh** with an animated spinner

### ⚙️ Configurable
All settings live in the DMS plugin settings panel:

- Toggle each provider on/off individually
- Paste API keys & cookies (stored locally in `plugin_settings.json`)
- Adjust the refresh interval (30 s → 30 min)
- Toggle compact bar mode

---

## Installation

### Prerequisites

| Tool | Why |
|---|---|
| `bash` | Runs the data fetcher |
| `jq` | Parses & transforms JSON |
| `curl` | Calls remote APIs (Cursor, DeepSeek, OpenCode, Antigravity) |
| `sqlite3` | Reads Cursor's local DB and Hermes session database |

Most Linux desktops have these already. On Arch:
```bash
sudo pacman -S jq curl sqlite
```

### Install the Plugin

Clone this repository into your DMS plugins directory:

```bash
git clone https://github.com/dpxwz/CodingQuotas.git \
    ~/.config/DankMaterialShell/plugins/CodingQuotas
```

Then restart DankMaterialShell or reload plugins from the DMS settings panel.

### Provider-Specific Setup

#### Codex, Cursor, Antigravity
These are **zero-config** — the fetcher reads from local sessions, app databases, or process inspection. Just make sure the respective tool is installed and has been used at least once.

#### DeepSeek
1. Go to [platform.deepseek.com → API Keys](https://platform.deepseek.com/api_keys)
2. Create a key (only `GET /user/balance` is called)
3. Paste it in the plugin settings under **DeepSeek API key**

#### OpenCode Go
1. Open [opencode.ai](https://opencode.ai) in your browser and log in
2. Navigate to your workspace dashboard — copy the workspace ID from the URL:
   `opencode.ai/workspace/<ID>/go`
3. Open DevTools → Application → Cookies → copy the `auth` cookie value
4. Paste both values in the plugin settings

#### Hermes
Zero-config if Hermes stores its sessions in `~/.hermes/state.db`. Just enable the "Hermes" toggle in settings.

---

## Architecture

```
CodingQuotas/
├── plugin.json                 # DMS plugin manifest
├── CodingQuotasWidget.qml      # Main widget UI (bar chips + popout panel)
├── CodingQuotasSettings.qml    # Settings panel (toggles, credentials, display)
├── fetch.sh                    # Bash data fetcher (runs all providers in parallel)
├── icons/                      # SVG logos for each provider
│   ├── antigravity.svg
│   ├── codex.svg
│   ├── cursor.svg
│   ├── deepseek.svg
│   └── opencode.svg
└── README.md
```

### Data Flow

```
┌─────────────┐   bash + curl/sqlite3   ┌─────────────┐
│  fetch.sh   │ ───────────────────────▶ │  JSON blob   │
│  (parallel) │   per-provider funcs     │  to stdout   │
└─────────────┘                          └──────┬──────┘
                                                │
         QML Timer (every N sec)                │
              calls Proc.runCommand             │
                                                ▼
┌──────────────────────┐              ┌─────────────────┐
│ CodingQuotasWidget   │◀─────────── │  JSON.parse()    │
│  • bar chips         │  qdata      │  in QML callback │
│  • popout panel      │             └─────────────────┘
│  • token trackers    │
└──────────────────────┘
```

### Output Schema

`fetch.sh` emits a single JSON object to stdout:

```jsonc
{
  "ts": 1718000000,          // fetch timestamp (epoch seconds)
  "providers": [             // one entry per enabled provider
    {
      "id": "codex",
      "name": "Codex",
      "icon": "bolt",
      "ok": true,
      "error": null,
      "level": "ok",         // "ok" | "warn" | "crit" | "neutral" | "err"
      "headlinePct": 67,     // remaining %, drives bar color
      "headlineText": "67%",
      "sub": "Pro",          // plan tier
      "windows": [
        { "label": "5h",     "remainingPct": 67, "resetAt": 1718003600, "detail": null },
        { "label": "Weekly", "remainingPct": 92, "resetAt": 1718200000, "detail": null }
      ],
      "updatedAt": 1717999000,
      "stale": false,
      "tokenTracker": { /* ... */ }  // Codex only
    }
    // ...
  ],
  "hermes": { /* token stats */ } | null
}
```

---

## Configuration Reference

All settings are stored in `~/.config/DankMaterialShell/plugin_settings.json` under the `codingQuotas` key.

| Key | Type | Default | Description |
|---|---|---|---|
| `enableCodex` | bool | `true` | Show Codex quota |
| `enableCursor` | bool | `true` | Show Cursor quota |
| `enableAntigravity` | bool | `true` | Show Antigravity quota |
| `enableDeepseek` | bool | `true` | Show DeepSeek balance |
| `enableOpencodeGo` | bool | `true` | Show OpenCode Go quota |
| `enableHermes` | bool | `true` | Show Hermes token tracker |
| `deepseekApiKey` | string | `""` | DeepSeek API key |
| `opencodeCookie` | string | `""` | opencode.ai auth cookie |
| `opencodeWorkspaceId` | string | `""` | opencode.ai workspace ID |
| `compactBar` | bool | `false` | Icons-only mode in the bar |
| `refreshIntervalSec` | number | `300` | Auto-refresh interval (30–1800 s) |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Codex shows "—" | No `~/.codex/sessions` found | Run Codex at least once |
| Codex shows 0% but quota has reset | Stale session data with past `resets_at` | Refresh — the fetcher auto-detects past resets |
| Cursor shows "session expired" | Cursor access token rotated | Reopen Cursor IDE to refresh the token |
| Antigravity shows "not running" | No `language_server` process found | Start the Antigravity IDE |
| OpenCode shows "cookie expired" | Auth cookie has expired | Re-copy the cookie from DevTools |
| DeepSeek shows "auth failed" | Invalid or revoked API key | Regenerate the key on platform.deepseek.com |

---

## Contributing

Pull requests are welcome! If you'd like to add a new provider:

1. Add a `<provider>_fetch()` function in `fetch.sh` that outputs the standard JSON schema
2. Add the provider ID to the `ALL` list and an `enable_key` mapping
3. Add a toggle in `CodingQuotasSettings.qml`
4. Add an SVG icon to `icons/`


