#!/usr/bin/env bash
# Coding Plan Quotas — data fetcher for the DankMaterialShell widget.
#
# Outputs normalized JSON describing remaining quota / balance for each
# enabled coding plan. Reads its own settings (toggles + secrets) directly
# from DMS plugin_settings.json, so no secret is ever passed on argv.
#
# Usage:
#   fetch.sh all                 # every enabled provider (parallel)
#   fetch.sh codex|cursor|antigravity|deepseek|opencodeGo
#
# Result schema (one object per provider):
# {
#   "id","name","icon","ok","error","level",
#   "headlinePct"  : number|null,   # remaining %, drives bar color
#   "headlineText" : "99%" | "¥0.98",
#   "sub"          : "Plus",
#   "windows": [ {label, remainingPct|null, resetAt|null(epoch s), detail|null} ],
#   "updatedAt": epoch|null, "stale": bool
# }

set -u
export LC_ALL=C
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH"

PSF="${DMS_PLUGIN_SETTINGS:-$HOME/.config/DankMaterialShell/plugin_settings.json}"
TIMEOUT=15

cfg() { jq -r --arg k "$1" '.codingQuotas[$k] // empty' "$PSF" 2>/dev/null; }
# A provider is enabled unless its toggle is explicitly false.
is_enabled() { [ "$(cfg "$1")" != "false" ]; }

mkerr() { # id name icon error headlineText sub
    jq -n --arg id "$1" --arg name "$2" --arg icon "$3" --arg error "$4" \
        --arg ht "${5:-—}" --arg sub "${6:-}" \
        '{id:$id,name:$name,icon:$icon,ok:false,error:$error,level:"err",
          headlinePct:null,headlineText:$ht,sub:$sub,windows:[],updatedAt:null,stale:false}'
}

# ----------------------------------------------------------------------------
codex_fetch() {
    local dir="$HOME/.codex/sessions"
    [ -d "$dir" ] || { mkerr codex Codex bolt "no codex sessions" "—" "not found"; return; }
    local newest path mtime
    newest=$(find "$dir" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1)
    [ -n "$newest" ] || { mkerr codex Codex bolt "no sessions" "—" ""; return; }
    mtime=${newest%% *}; mtime=${mtime%.*}
    path=${newest#* }
    local line
    line=$(tac "$path" 2>/dev/null | grep -m1 '"rate_limits"')
    [ -n "$line" ] || { mkerr codex Codex bolt "no rate-limit data yet" "—" ""; return; }
    local rl
    rl=$(printf '%s' "$line" | jq -c 'first(.. | objects | select(has("primary") and has("plan_type")))' 2>/dev/null)
    [ -n "$rl" ] && [ "$rl" != "null" ] || { mkerr codex Codex bolt "parse error" "—" ""; return; }
    local now stale=false
    now=$(date +%s)
    [ $((now - mtime)) -gt 86400 ] && stale=true
    printf '%s' "$rl" | jq -c --argjson mtime "$mtime" --argjson stale "$stale" '
        (((.primary.used_percent)   // 0)) as $pu |
        (((.secondary.used_percent) // 0)) as $su |
        ((100 - $pu) | floor) as $pr |
        ((100 - $su) | floor) as $sr |
        ([$pr,$sr] | min) as $head |
        ((.plan_type // "") | if . == "" then "" else (.[0:1] | ascii_upcase) + .[1:] end) as $plan |
        {id:"codex",name:"Codex",icon:"bolt",ok:true,error:null,
         level:(if $head<15 then "crit" elif $head<40 then "warn" else "ok" end),
         headlinePct:$head, headlineText:($head|tostring)+"%", sub:$plan,
         windows:[
            {label:"5h",     remainingPct:$pr, resetAt:(.primary.resets_at   // null), detail:null},
            {label:"Weekly", remainingPct:$sr, resetAt:(.secondary.resets_at // null), detail:null}
         ],
         updatedAt:$mtime, stale:$stale}'
}

# ----------------------------------------------------------------------------
cursor_fetch() {
    local db="$HOME/.config/Cursor/User/globalStorage/state.vscdb"
    [ -f "$db" ] || { mkerr cursor Cursor code "Cursor not installed" "—" ""; return; }
    local tok mem
    tok=$(sqlite3 "file:$db?mode=ro" "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';" 2>/dev/null)
    [ -n "$tok" ] || { mkerr cursor Cursor code "not logged in to Cursor" "—" ""; return; }
    mem=$(sqlite3 "file:$db?mode=ro" "SELECT value FROM ItemTable WHERE key='cursorAuth/stripeMembershipType';" 2>/dev/null)
    local payload pad sub uid
    payload=$(printf '%s' "$tok" | cut -d. -f2)
    pad=$(( (4 - ${#payload} % 4) % 4 )); payload="$payload$(printf '%*s' "$pad" | tr ' ' '=')"
    sub=$(printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.sub // empty' 2>/dev/null)
    uid="${sub##*|}"
    [ -n "$uid" ] || { mkerr cursor Cursor code "could not read session" "—" ""; return; }
    local resp
    resp=$(curl -s --max-time "$TIMEOUT" 'https://cursor.com/api/dashboard/get-current-period-usage' \
        -X POST -H 'Content-Type: application/json' \
        -H 'Origin: https://cursor.com' -H 'Referer: https://cursor.com/dashboard' \
        -H "Cookie: WorkosCursorSessionToken=${uid}%3A%3A${tok}" --data '{}' 2>/dev/null)
    echo "$resp" | jq -e '.planUsage' >/dev/null 2>&1 || { mkerr cursor Cursor code "session expired — reopen Cursor" "—" "${mem:-}"; return; }
    local now; now=$(date +%s)
    echo "$resp" | jq -c --arg mem "${mem:-pro}" --argjson now "$now" '
        .planUsage as $p |
        ((100 - (($p.totalPercentUsed) // 0)) | floor) as $rem |
        (($p.limit // 0) / 100) as $lim |
        (($p.autoPercentUsed // 0) | round) as $auto |
        (($p.apiPercentUsed  // 0) | round) as $api |
        {id:"cursor",name:"Cursor",icon:"code",ok:true,error:null,
         level:(if $rem<15 then "crit" elif $rem<40 then "warn" else "ok" end),
         headlinePct:$rem, headlineText:($rem|tostring)+"%",
         sub:($mem|ascii_upcase),
         windows:[
            {label:"Included usage", remainingPct:$rem,
             resetAt:(((.billingCycleEnd // "0")|tonumber)/1000|floor),
             detail:("$" + ($lim|tostring) + " plan · Auto " + ($auto|tostring)
                     + "% / API " + ($api|tostring) + "% used")}
         ],
         updatedAt:$now, stale:false}'
}

# ----------------------------------------------------------------------------
antigravity_fetch() {
    local pid
    pid=$(pgrep -f 'language_server.*antigravity' 2>/dev/null | head -1)
    [ -n "$pid" ] || { mkerr antigravity Antigravity rocket_launch "Antigravity not running" "—" ""; return; }
    local csrf
    csrf=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk '/^--csrf_token$/{getline; print; exit}')
    [ -n "$csrf" ] || { mkerr antigravity Antigravity rocket_launch "no csrf token" "—" ""; return; }
    local ports
    ports=$(ss -tlnp 2>/dev/null | grep "pid=$pid," | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2 | sort -u)
    [ -n "$ports" ] || { mkerr antigravity Antigravity rocket_launch "no local ports" "—" ""; return; }
    local body='{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}'
    local resp="" p
    for p in $ports; do
        resp=$(curl -sk --max-time 6 \
            "https://127.0.0.1:$p/exa.language_server_pb.LanguageServerService/GetUserStatus" \
            -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \
            -H "x-codeium-csrf-token: $csrf" --data "$body" 2>/dev/null)
        echo "$resp" | jq -e '.userStatus' >/dev/null 2>&1 && break || resp=""
    done
    [ -n "$resp" ] || { mkerr antigravity Antigravity rocket_launch "language-server probe failed" "—" ""; return; }
    local now; now=$(date +%s)
    echo "$resp" | jq -c --argjson now "$now" '
        .userStatus as $u |
        ($u.planStatus.planInfo.planName // "?") as $plan |
        [ ($u.cascadeModelConfigData.clientModelConfigs // [])[]
          | select(.quotaInfo != null)
          | {label:(.label // "model"),
             remainingPct:(((.quotaInfo.remainingFraction) // 0) * 100 | floor),
             resetAt:((.quotaInfo.resetTime // "") | if . == "" then null else (try fromdateiso8601 catch null) end),
             detail:null} ] as $wins |
        (if ($wins|length) > 0 then ($wins | map(.remainingPct) | min) else 100 end) as $head |
        {id:"antigravity",name:"Antigravity",icon:"rocket_launch",ok:true,error:null,
         level:(if $head<15 then "crit" elif $head<40 then "warn" else "ok" end),
         headlinePct:$head, headlineText:($head|tostring)+"%", sub:$plan,
         windows:$wins, updatedAt:$now, stale:false}'
}

# ----------------------------------------------------------------------------
deepseek_fetch() {
    local key; key=$(cfg deepseekApiKey)
    [ -n "$key" ] || { mkerr deepseek DeepSeek savings "set DeepSeek API key in settings" "—" "setup"; return; }
    local resp
    resp=$(curl -s --max-time "$TIMEOUT" 'https://api.deepseek.com/user/balance' \
        -H "Authorization: Bearer $key" 2>/dev/null)
    echo "$resp" | jq -e '.balance_infos' >/dev/null 2>&1 || { mkerr deepseek DeepSeek savings "auth failed — check API key" "—" ""; return; }
    local now; now=$(date +%s)
    echo "$resp" | jq -c --argjson now "$now" '
        (.is_available // false) as $av |
        (.balance_infos[0]) as $b |
        ($b.currency // "CNY") as $cur |
        (if $cur=="CNY" then "¥" else "$" end) as $sym |
        {id:"deepseek",name:"DeepSeek",icon:"savings",ok:true,error:null,
         level:(if $av then "neutral" else "crit" end),
         headlinePct:null, headlineText:($sym + ($b.total_balance // "0")),
         sub:(if $av then "available" else "insufficient" end),
         windows:[ (.balance_infos[] |
            {label:(.currency + " balance"), remainingPct:null, resetAt:null,
             detail:((if .currency=="CNY" then "¥" else "$" end) + .total_balance
                     + "  (topped-up " + (.topped_up_balance // "0")
                     + ", granted " + (.granted_balance // "0") + ")")}) ],
         updatedAt:$now, stale:false}'
}

# ----------------------------------------------------------------------------
opencode_fetch() {
    local cookie wsid
    cookie=$(cfg opencodeCookie)
    wsid=$(cfg opencodeWorkspaceId)
    [ -n "$cookie" ] || { mkerr opencodeGo "OpenCode Go" terminal "set opencode.ai auth cookie in settings" "—" "setup"; return; }
    [ -n "$wsid" ]   || { mkerr opencodeGo "OpenCode Go" terminal "set opencode.ai workspace ID in settings" "—" "setup"; return; }
    # Accept either a raw cookie value or a full "name=value" / "a=b; c=d" string.
    case "$cookie" in
        *=*) : ;;                      # already key=value form
        *)   cookie="auth=$cookie" ;;  # bare value -> assume the auth cookie
    esac
    # The workspace dashboard is SolidJS-SSR'd; usage lives in the hydration blob as
    #   <window>Usage:$R[..]={ ... usagePercent:NN ... resetInSec:NN ... }
    # Flatten newlines so the [^}]* object match can't be split across lines.
    local ua='Mozilla/5.0 (X11; Linux x86_64; rv:148.0) Gecko/20100101 Firefox/148.0'
    local html
    html=$(curl -s --max-time "$TIMEOUT" "https://opencode.ai/workspace/${wsid}/go" \
        -H "User-Agent: $ua" -H 'Accept: text/html' -H "Cookie: $cookie" 2>/dev/null | tr '\n\r\t' '   ')
    [ -n "$html" ] || { mkerr opencodeGo "OpenCode Go" terminal "no response from opencode.ai" "—" ""; return; }

    # Pull "<usagePct> <resetInSec>" for one window object, order-independent.
    # SSR emits each window twice: a real "$R[..]={...usagePercent:NN...}" object
    # and a "<key>:null" reference. Their order varies, so require the block to
    # actually contain usagePercent instead of blindly taking the first match.
    ocg_win() {
        local block pct reset
        block=$(grep -oP "$2:[^}]*usagePercent[^}]*}" <<<"$1" | head -1)
        [ -n "$block" ] || return 1
        pct=$(grep -oP 'usagePercent:\s*\K-?[0-9]+(\.[0-9]+)?'  <<<"$block" | head -1)
        reset=$(grep -oP 'resetInSec:\s*\K-?[0-9]+(\.[0-9]+)?' <<<"$block" | head -1)
        [ -n "$pct" ] || return 1
        echo "$pct ${reset:-0}"
    }

    local now r5 rw rm; now=$(date +%s)
    r5=$(ocg_win "$html" rollingUsage)
    rw=$(ocg_win "$html" weeklyUsage)
    rm=$(ocg_win "$html" monthlyUsage)

    if [ -z "$r5" ] && [ -z "$rw" ] && [ -z "$rm" ]; then
        if grep -qiE 'sign[ -]?in|log[ -]?in|unauthor|"/auth' <<<"$html"; then
            mkerr opencodeGo "OpenCode Go" terminal "cookie expired — re-copy auth cookie" "—" ""
        else
            mkerr opencodeGo "OpenCode Go" terminal "could not parse dashboard (check workspace ID)" "—" ""
        fi
        return
    fi

    local wins="" spec label val pct reset rem rat j
    for spec in "5h:$r5" "Weekly:$rw" "Monthly:$rm"; do
        label=${spec%%:*}; val=${spec#*:}
        [ -n "$val" ] || continue
        pct=${val%% *}; reset=${val##* }
        rem=$(awk -v p="$pct"  'BEGIN{r=100-p; if(r<0)r=0; printf "%d", r}')
        rat=$(awk -v n="$now" -v s="$reset" 'BEGIN{printf "%d", n+s}')
        j=$(printf '{"label":"%s","remainingPct":%s,"resetAt":%s,"detail":null}' "$label" "$rem" "$rat")
        [ -n "$wins" ] && wins="$wins,"; wins="$wins$j"
    done

    echo "[$wins]" | jq -c --argjson now "$now" '
        . as $w |
        ([$w[].remainingPct] | min) as $head |
        {id:"opencodeGo",name:"OpenCode Go",icon:"terminal",ok:true,error:null,
         level:(if $head<15 then "crit" elif $head<40 then "warn" else "ok" end),
         headlinePct:$head, headlineText:($head|tostring)+"%", sub:"Zen",
         windows:$w, updatedAt:$now, stale:false}'
}

# ----------------------------------------------------------------------------
run_one() {
    case "$1" in
        codex)       codex_fetch ;;
        cursor)      cursor_fetch ;;
        antigravity) antigravity_fetch ;;
        deepseek)    deepseek_fetch ;;
        opencodeGo)  opencode_fetch ;;
        *) mkerr "$1" "$1" help "unknown provider" "—" "" ;;
    esac
}

enable_key() {
    case "$1" in
        codex) echo enableCodex ;;
        cursor) echo enableCursor ;;
        antigravity) echo enableAntigravity ;;
        deepseek) echo enableDeepseek ;;
        opencodeGo) echo enableOpencodeGo ;;
    esac
}

ALL="codex cursor antigravity deepseek opencodeGo"
arg="${1:-all}"

if [ "$arg" = "all" ]; then
    list=""
    for p in $ALL; do
        is_enabled "$(enable_key "$p")" && list="$list $p"
    done
else
    list="$arg"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/codingquotas.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
i=0
for p in $list; do
    run_one "$p" > "$tmp/$(printf '%02d' "$i").json" 2>/dev/null &
    i=$((i+1))
done
wait

jq -s --argjson ts "$(date +%s)" '{ts:$ts, providers:[ .[] | select(. != null) ]}' "$tmp"/*.json 2>/dev/null \
    || echo '{"ts":0,"providers":[]}'
