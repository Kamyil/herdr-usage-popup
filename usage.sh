#!/usr/bin/env bash
# Usage Popup — model usage bars for a Herdr popup panel.
#
# One collector per provider, each reading that provider's own CLI usage
# surface. No credential file is read, written, or refreshed by this plugin;
# the owning CLI handles auth, and a failure surfaces as an error line.
#
#   openai-codex  `codex app-server`  -> account/read + account/rateLimits/read
#   claude        statusLine snapshot written by claude-statusline.sh
#   opencode-go   `omp usage --json --provider opencode-go`
#
# OpenCode Go's key exists only inside oh-my-pi (the `opencode` CLI reports zero
# credentials), so `omp` is the only supported way to read it. Claude Code has
# no usage command; it reports subscription windows to its statusLine command,
# which claude-hook.sh installs.
#
# Controls: r refresh, q/Esc/Enter close. Auto-refreshes while open.
set -uo pipefail

OMP_BIN="${HERDR_USAGE_OMP_BIN:-omp}"
CODEX_BIN="${HERDR_USAGE_CODEX_BIN:-codex}"
REFRESH_SECONDS="${HERDR_USAGE_REFRESH_SECONDS:-60}"
BAR_WIDTH="${HERDR_USAGE_BAR_WIDTH:-24}"
WINDOW_COL=14
SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
QUIT=0

# Fractional `read -t` is bash 4+. Bash 3.2 (macOS /bin/bash) still gets the
# spinner, but cannot be interrupted mid-fetch.
FRACTIONAL_TIMEOUT=0
(( ${BASH_VERSINFO[0]:-3} >= 4 )) && FRACTIONAL_TIMEOUT=1

US=$(printf '\037')
COLLECTORS=(collect_codex collect_claude collect_opencode_go)

state_dir() {
  if [[ -n ${HERDR_USAGE_STATE_DIR:-} ]]; then printf '%s' "$HERDR_USAGE_STATE_DIR"
  elif [[ -n ${HERDR_PLUGIN_STATE_DIR:-} ]]; then printf '%s' "$HERDR_PLUGIN_STATE_DIR"
  else printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-usage-popup"
  fi
}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-usage-popup.XXXXXX") || WORK_DIR=""
ROWS_TMP="${WORK_DIR:+$WORK_DIR/rows}"
cleanup() { [[ -n $WORK_DIR ]] && rm -rf "$WORK_DIR"; }
trap 'cleanup; printf "\033[H\033[2J"; exit 0' INT TERM HUP
trap cleanup EXIT

duration() { # seconds -> 3d19h / 46m
  local s=$1 d h m
  if (( s <= 0 )); then printf 'now'; return; fi
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if (( d > 0 )); then printf '%dd%02dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

bar() { # percent -> block bar
  local pct=$1 filled empty f='' e=''
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  filled=$(( pct * BAR_WIDTH / 100 ))
  empty=$(( BAR_WIDTH - filled ))
  (( filled > 0 )) && f=$(printf '█%.0s' $(seq 1 "$filled"))
  (( empty > 0 )) && e=$(printf '░%.0s' $(seq 1 "$empty"))
  printf '%s%s' "$f" "$e"
}

pretty_provider() {
  case "$1" in
    openai-codex) printf 'OpenAI Codex' ;;
    claude) printf 'Claude Code' ;;
    opencode-go) printf 'OpenCode Go' ;;
    anthropic) printf 'Anthropic' ;;
    openai) printf 'OpenAI' ;;
    google) printf 'Google' ;;
    xai) printf 'xAI' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Row contract, unit-separated on stdout:
#   provider <US> plan <US> account <US> window <US> percent <US> reset_unix_s
# A `window` beginning with `!` is a status line: the remaining fields are empty.
error_row() { printf '%s\037%s\037%s\037!%s\037\037\n' "$1" "" "" "$2"; }

# Codex reports its own limits over the app-server JSON-RPC surface, so the
# plugin never touches ~/.codex/auth.json.
collect_codex() {
  local key=openai-codex bin dir fifo out pid i
  bin=$(command -v "$CODEX_BIN") || return 0
  [[ -n $WORK_DIR ]] || return 0
  dir="$WORK_DIR/codex"
  rm -rf "$dir"
  mkdir -p "$dir" || return 0
  fifo="$dir/in"; out="$dir/out"
  mkfifo "$fifo" 2>/dev/null || return 0

  # `exec 3<>` opens the FIFO read+write without blocking, and holding that fd
  # keeps the server's stdin open: app-server exits on EOF before answering.
  exec 3<> "$fifo"
  "$bin" -s read-only -a untrusted app-server < "$fifo" > "$out" 2>/dev/null &
  pid=$!
  printf '%s\n' \
    '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"herdr-usage-popup","version":"1"}}}' \
    '{"method":"initialized","params":{}}' \
    '{"id":2,"method":"account/read","params":{}}' \
    '{"id":3,"method":"account/rateLimits/read","params":{}}' >&3

  i=0
  while (( i < 100 )); do
    grep -q '"id":3' "$out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$(( i + 1 ))
  done

  exec 3>&-
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  if ! jq -e -s 'any(.[]; .id == 3 and .result.rateLimits)' "$out" > /dev/null 2>&1; then
    rm -rf "$dir"
    error_row "$key" 'codex app-server returned no limits'
    return 0
  fi

  jq -rs --arg p "$key" '
    def wlabel($m):
      if $m == null or $m == 0 then "?"
      elif ($m % 1440) == 0 then "\($m / 1440 | floor)d"
      elif ($m % 60) == 0 then "\($m / 60 | floor)h"
      else "\($m)m" end;
    ([.[] | select(.id == 2) | .result.account][0] // {}) as $acct
    | ([.[] | select(.id == 3) | .result][0] // {}) as $res
    | ($acct.planType // $res.rateLimits.planType // "") as $plan
    | ($acct.email // "") as $email
    | (if (($res.rateLimitsByLimitId // {}) | length) > 0
       then ($res.rateLimitsByLimitId
             | to_entries
             | map(.value + { limitId: .key })
             | sort_by(if .limitId == "codex" then 0 else 1 end))
       else [ ($res.rateLimits + { limitId: "codex" }) ] end)
    | .[] as $lim
    | (if $lim.limitId == "codex" then "" else ($lim.limitName // $lim.limitId) end) as $q
    | ([ { w: $lim.primary }, { w: $lim.secondary } ])
    | .[]
    | select(.w != null and .w.usedPercent != null)
    | [ $p, $plan, $email,
        (wlabel(.w.windowDurationMins) + (if $q != "" then "/" + $q else "" end)),
        (.w.usedPercent | floor),
        (.w.resetsAt // 0) ]
    | map(tostring) | join("\u001f")' "$out"

  rm -rf "$dir"
}

# Claude Code reports its subscription windows to whatever statusLine command
# it is configured with; `claude-statusline.sh` records that payload here.
collect_claude() {
  local key=claude snapshot state limits recorded age max_age
  state=$(state_dir)
  snapshot="$state/claude-statusline.json"
  [[ -f $snapshot ]] || return 0

  limits=$(jq -c '.rateLimits // empty' "$snapshot" 2>/dev/null)
  if [[ -z $limits || $limits == null ]]; then
    error_row "$key" 'snapshot has no rate limits'
    return 0
  fi

  recorded=$(jq -r '.recordedAt // 0' "$snapshot" 2>/dev/null)
  max_age="${HERDR_USAGE_CLAUDE_MAX_AGE:-900}"
  age=$(( $(date +%s) - ${recorded:-0} ))
  if (( age > max_age )); then
    error_row "$key" "last snapshot $(duration "$age") old — run Claude Code to refresh"
  fi

  printf '%s' "$limits" | jq -r --arg p "$key" '
    [ { w: "5h", d: .five_hour }, { w: "7d", d: .seven_day } ]
    | .[]
    | select(.d != null and .d.used_percentage != null)
    | [ $p, "", "", .w, (.d.used_percentage | round), (.d.resets_at // 0) ]
    | map(tostring) | join("\u001f")'
}

collect_opencode_go() {
  local key=opencode-go json
  if ! command -v "$OMP_BIN" > /dev/null 2>&1; then
    error_row "$key" "$OMP_BIN not found (the OpenCode Go credential lives in oh-my-pi)"
    return 0
  fi
  if ! json=$("$OMP_BIN" usage --json --provider "$key" 2>/dev/null); then
    error_row "$key" 'request failed'
    return 0
  fi
  printf '%s' "$json" | jq -r --arg p "$key" '
    .reports[]?
    | select(.provider == $p)
    | ((.metadata // {}).planType // "") as $plan
    | .limits[]?
    | [ $p, $plan, "",
        ((.scope.windowId // "?") | if . == "monthly" then "mo" else . end),
        ((.amount.usedFraction // 0) * 100 | floor),
        ((.window.resetsAt // 0) / 1000 | floor) ]
    | map(tostring) | join("\u001f")'
}

# Runs every collector, animating a spinner while they fetch. Rows land in
# ROWS_TMP only; the spinner is the sole thing written to the terminal.
run_collectors() {
  [[ -n $ROWS_TMP ]] || return 1
  local pid key frame i=0
  : > "$ROWS_TMP"
  ( trap - EXIT; for c in "${COLLECTORS[@]}"; do "$c"; done ) >> "$ROWS_TMP" 2>/dev/null &
  pid=$!

  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      frame=${SPINNER_FRAMES[$(( i % ${#SPINNER_FRAMES[@]} ))]}
      printf '\r\033[K  %s fetching usage…' "$frame"
      i=$(( i + 1 ))
      if (( FRACTIONAL_TIMEOUT )) && [[ -t 0 ]]; then
        if IFS= read -rsn1 -t 0.1 key; then
          case "$key" in
            q | Q | $'\e' | $'\r' | $'\n' | $'\x03') QUIT=1; kill "$pid" 2>/dev/null; break ;;
          esac
        fi
      else
        sleep 0.1
      fi
    done
    printf '\r\033[K'
  fi

  wait "$pid" 2>/dev/null
}

render() {
  printf '\033[H\033[2J'
  printf 'Model usage · %s\n\n' "$(date '+%H:%M')"

  if ! command -v jq > /dev/null 2>&1; then
    printf '  jq not found on PATH\n'
    return
  fi

  run_collectors
  (( QUIT )) && return

  local rows
  rows=$(< "$ROWS_TMP")
  if [[ -z $rows ]]; then
    printf '  no usage available — no provider CLI found\n'
    return
  fi

  local now provider plan account window pct resets head last=''
  now=$(date +%s)
  while IFS="$US" read -r provider plan account window pct resets; do
    [[ -n $provider ]] || continue
    if [[ $provider != "$last" ]]; then
      [[ -n $last ]] && printf '\n'
      head=$(pretty_provider "$provider")
      [[ -n $plan ]] && head+=" · $plan"
      [[ -n $account ]] && head+=" · $account"
      printf '%s\n' "$head"
      last=$provider
    fi
    if [[ $window == '!'* ]]; then
      printf '  %s\n' "${window#!}"
      continue
    fi
    local reset=''
    (( resets > 0 )) && reset="  resets $(duration $(( resets - now )))"
    printf '  %-*s %s %3d%%%s\n' "$WINDOW_COL" "$window" "$(bar "$pct")" "$pct" "$reset"
  done <<< "$rows"
}

print_footer() { printf '\n\nr refresh · q close\n'; }

render
if (( QUIT )); then printf '\033[H\033[2J'; exit 0; fi
print_footer

# Non-interactive runs (tests, pipes) render once and exit.
[[ -t 0 ]] || exit 0

while true; do
  if IFS= read -rsn1 -t "$REFRESH_SECONDS" key; then
    case "$key" in
      q | Q | $'\e' | $'\r' | $'\n' | $'\x03') break ;;
      r | R) : ;;
    esac
  fi
  render
  (( QUIT )) && break
  print_footer
done

printf '\033[H\033[2J'
