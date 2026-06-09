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
codex_token_stats() {
    local sessions_dir="$HOME/.codex/sessions"
    local today_in=0 today_out=0 today_cached=0 today_reasoning=0 today_total=0
    local history_json="["
    
    local i d day_dir f val ttu tot in out cached reasoning date_str day_sum
    for i in {0..29}; do
        d=$(date -d "$i days ago" +%Y/%m/%d)
        day_dir="$sessions_dir/$d"
        day_sum=0
        if [ -d "$day_dir" ]; then
            while read -r f; do
                [ -f "$f" ] || continue
                val=$(tac "$f" 2>/dev/null | grep -m1 '"type"[[:space:]]*:[[:space:]]*"token_count"')
                if [ -n "$val" ]; then
                    ttu=$(grep -oP '"total_token_usage"\s*:\s*\{[^\}]+\}' <<< "$val")
                    if [ -n "$ttu" ]; then
                        tot=$(grep -oP '"total_tokens"\s*:\s*\K[0-9]+' <<< "$ttu")
                        day_sum=$((day_sum + ${tot:-0}))
                        
                        if [ "$i" -eq 0 ]; then
                            in=$(grep -oP '"input_tokens"\s*:\s*\K[0-9]+' <<< "$ttu")
                            out=$(grep -oP '"output_tokens"\s*:\s*\K[0-9]+' <<< "$ttu")
                            cached=$(grep -oP '"cached_input_tokens"\s*:\s*\K[0-9]+' <<< "$ttu")
                            reasoning=$(grep -oP '"reasoning_output_tokens"\s*:\s*\K[0-9]+' <<< "$ttu")
                            
                            today_in=$((today_in + ${in:-0}))
                            today_out=$((today_out + ${out:-0}))
                            today_cached=$((today_cached + ${cached:-0}))
                            today_reasoning=$((today_reasoning + ${reasoning:-0}))
                            today_total=$((today_total + ${tot:-0}))
                        fi
                    fi
                fi
            done < <(find "$day_dir" -type f -name '*.jsonl' 2>/dev/null)
        fi
        date_str=$(date -d "$i days ago" +%Y-%m-%d)
        if [ "$i" -gt 0 ]; then
            history_json="${history_json},"
        fi
        history_json="${history_json}{\"date\":\"$date_str\",\"total\":$day_sum}"
    done
    history_json="${history_json}]"
    
    jq -n \
       --argjson in "$today_in" \
       --argjson out "$today_out" \
       --argjson cached "$today_cached" \
       --argjson reasoning "$today_reasoning" \
       --argjson total "$today_total" \
       --argjson history "$history_json" \
       '{today:{input:$in,output:$out,cached:$cached,reasoning:$reasoning,total:$total},history:$history}'
}

# ----------------------------------------------------------------------------
codex_fetch() {
    local dir="$HOME/.codex/sessions"
    [ -d "$dir" ] || { mkerr codex Codex bolt "no codex sessions" "—" "not found"; return; }
    
    # 1. Determine if the most recent active session ended with a "premium" rate limit (i.e. codex exhausted)
    local newest_file newest_mtime newest_path latest_line latest_limit_id
    local codex_exhausted=false
    newest_file=$(find "$dir" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1)
    if [ -n "$newest_file" ]; then
        newest_mtime=${newest_file%% *}; newest_mtime=${newest_mtime%.*}
        newest_path=${newest_file#* }
        local now; now=$(date +%s)
        # Only check exhaustion if the newest session is recent (within 24 hours)
        if [ $((now - newest_mtime)) -le 86400 ]; then
            latest_line=$(tac "$newest_path" 2>/dev/null | grep -m1 '"rate_limits"')
            if [ -n "$latest_line" ]; then
                latest_limit_id=$(printf '%s' "$latest_line" | jq -r '.. | objects | select(has("limit_id")) | .limit_id' 2>/dev/null | head -1)
                if [ "$latest_limit_id" = "premium" ]; then
                    codex_exhausted=true
                fi
            fi
        fi
    fi

    # 2. Find the newest session file and line containing actual "codex" rate limits
    local newest path mtime line=""
    while read -r newest; do
        [ -n "$newest" ] || continue
        mtime=${newest%% *}; mtime=${mtime%.*}
        path=${newest#* }
        line=$(tac "$path" 2>/dev/null | grep -m1 -E '"limit_id"[[:space:]]*:[[:space:]]*"codex"')
        if [ -n "$line" ]; then
            break
        fi
    done < <(find "$dir" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -nr)

    # Fallback to the original method if no codex rate limit was found in any session file
    if [ -z "$line" ]; then
        newest=$(find "$dir" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1)
        [ -n "$newest" ] || { mkerr codex Codex bolt "no sessions" "—" ""; return; }
        mtime=${newest%% *}; mtime=${mtime%.*}
        path=${newest#* }
        line=$(tac "$path" 2>/dev/null | grep -m1 '"rate_limits"')
        [ -n "$line" ] || { mkerr codex Codex bolt "no rate-limit data yet" "—" ""; return; }
    fi

    local rl
    rl=$(printf '%s' "$line" | jq -c 'first(.. | objects | select(.limit_id == "codex"))' 2>/dev/null)
    # Fallback to general primary/plan_type select if limit_id selector is empty
    if [ -z "$rl" ] || [ "$rl" = "null" ]; then
        rl=$(printf '%s' "$line" | jq -c 'first(.. | objects | select(has("primary") and has("plan_type")))' 2>/dev/null)
    fi
    [ -n "$rl" ] && [ "$rl" != "null" ] || { mkerr codex Codex bolt "parse error" "—" ""; return; }
    local now stale=false
    now=$(date +%s)
    [ $((now - mtime)) -gt 86400 ] && stale=true
    
    local stats; stats=$(codex_token_stats)
    # Pass whether codex is exhausted as a parameter to jq
    printf '%s' "$rl" | jq -c --argjson mtime "$mtime" \
        --argjson stale "$stale" \
        --argjson exhausted "$codex_exhausted" \
        --argjson tokenTracker "$stats" '
        (if $exhausted or .limit_id == "premium" then 100 else (((.primary.used_percent) // 0)) end) as $pu |
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
         updatedAt:$mtime, stale:$stale, tokenTracker:$tokenTracker}'
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
        (($p.limit // 0) / 100) as $lim |
        (($p.autoPercentUsed // 0) | round) as $auto |
        (($p.apiPercentUsed  // 0) | round) as $api |
        ((100 - $auto) | floor | if . < 0 then 0 else . end) as $autoRem |
        ((100 - $api) | floor | if . < 0 then 0 else . end) as $apiRem |
        ([$autoRem, $apiRem] | min) as $rem |
        {id:"cursor",name:"Cursor",icon:"code",ok:true,error:null,
         level:(if $rem<15 then "crit" elif $rem<40 then "warn" else "ok" end),
         headlinePct:$rem, headlineText:($rem|tostring)+"%",
         sub:($mem|ascii_upcase),
         windows:[
            {label:"Auto", remainingPct:$autoRem,
             resetAt:(((.billingCycleEnd // "0")|tonumber)/1000|floor),
             detail:("$" + ($lim|tostring) + " plan · Auto " + ($auto|tostring) + "% used")},
            {label:"API", remainingPct:$apiRem,
             resetAt:(((.billingCycleEnd // "0")|tonumber)/1000|floor),
             detail:("API " + ($api|tostring) + "% used")}
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
# ----------------------------------------------------------------------------
hermes_token_stats() {
    local DB_PATH="$HOME/.hermes/state.db"
    if [ ! -f "$DB_PATH" ]; then
        echo "null"
        return
    fi

    # Read data from sqlite
    local data
    data=$(sqlite3 -list -separator '|' "$DB_PATH" "SELECT date(started_at, 'unixepoch', 'localtime') as day, COALESCE(model, 'unknown') as model_name, SUM(input_tokens + output_tokens + cache_read_tokens) as total FROM sessions WHERE started_at >= unixepoch('now', 'localtime', '-29 days', 'start of day', 'utc') GROUP BY day, model_name;" 2>/dev/null)
    
    local history_json="["
    local i date_str day_total models_json first_model line m_name m_tokens
    for i in {0..29}; do
        date_str=$(date -d "$i days ago" +%Y-%m-%d)
        day_total=0
        models_json="["
        first_model=true
        while read -r line; do
            if [ -n "$line" ]; then
                m_name=$(echo "$line" | cut -d"|" -f2)
                m_tokens=$(echo "$line" | cut -d"|" -f3)
                day_total=$((day_total + m_tokens))
                if [ "$first_model" = false ]; then
                    models_json="${models_json},"
                fi
                models_json="${models_json}{\"model\":\"$m_name\",\"tokens\":$m_tokens}"
                first_model=false
            fi
        done < <(echo "$data" | grep "^$date_str|")
        models_json="${models_json}]"
        if [ "$i" -ne 0 ]; then
            history_json="${history_json},"
        fi
        history_json="${history_json}{\"date\":\"$date_str\",\"total\":$day_total,\"models\":$models_json}"
    done
    history_json="${history_json}]"

    local today_in=0 today_out=0 today_cached=0 today_reasoning=0 today_total=0
    local today_components
    today_components=$(sqlite3 -list -separator '|' "$DB_PATH" "SELECT COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0), COALESCE(SUM(cache_read_tokens), 0), COALESCE(SUM(reasoning_tokens), 0) FROM sessions WHERE started_at >= unixepoch('now', 'localtime', 'start of day', 'utc');" 2>/dev/null)
    if [ -n "$today_components" ]; then
        today_in=$(echo "$today_components" | cut -d"|" -f1)
        today_out=$(echo "$today_components" | cut -d"|" -f2)
        today_cached=$(echo "$today_components" | cut -d"|" -f3)
        today_reasoning=$(echo "$today_components" | cut -d"|" -f4)
        
        today_in=${today_in:-0}
        today_out=${today_out:-0}
        today_cached=${today_cached:-0}
        today_reasoning=${today_reasoning:-0}
        today_total=$((today_in + today_out + today_cached))
    fi

    jq -n \
       --argjson in "$today_in" \
       --argjson out "$today_out" \
       --argjson cached "$today_cached" \
       --argjson reasoning "$today_reasoning" \
       --argjson total "$today_total" \
       --argjson history "$history_json" \
       '{today:{input:$in,output:$out,cached:$cached,reasoning:$reasoning,total:$total},history:$history}'
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

ALL="codex cursor antigravity opencodeGo deepseek"
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

if is_enabled "enableHermes"; then
    hermes_token_stats > "$tmp/hermes_stats.tmp" 2>/dev/null &
fi

wait

hermes_json="null"
if [ -f "$tmp/hermes_stats.tmp" ]; then
    hermes_json=$(cat "$tmp/hermes_stats.tmp")
fi

jq -s --argjson ts "$(date +%s)" --argjson hermes "${hermes_json:-null}" \
    '{ts:$ts, providers:[ .[] | select(. != null) ], hermes:$hermes}' "$tmp"/*.json 2>/dev/null \
    || echo '{"ts":0,"providers":[],"hermes":null}'
