#!/usr/bin/env bash
# OMP Usage — model usage bars for a Herdr popup panel.
#
# Data source: `omp usage --json` (oh-my-pi's credential store and its own
# five-minute usage cache). Rendering is deliberately plain: no theme colors,
# no brand styling, no writes to Herdr config.
#
# Controls: r refresh, q/Esc/Enter close. Auto-refreshes while open.
set -uo pipefail

OMP_BIN="${HERDR_USAGE_OMP_BIN:-omp}"
REFRESH_SECONDS="${HERDR_USAGE_REFRESH_SECONDS:-60}"
BAR_WIDTH="${HERDR_USAGE_BAR_WIDTH:-24}"
WINDOW_COL=14
SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
QUIT=0

# Fractional `read -t` is bash 4+. Bash 3.2 (macOS /bin/bash) still gets the
# spinner, but cannot be interrupted mid-fetch.
FRACTIONAL_TIMEOUT=0
(( ${BASH_VERSINFO[0]:-3} >= 4 )) && FRACTIONAL_TIMEOUT=1

USAGE_TMP=$(mktemp "${TMPDIR:-/tmp}/herdr-omp-usage.XXXXXX") || USAGE_TMP=""
cleanup() { [[ -n $USAGE_TMP ]] && rm -f "$USAGE_TMP"; }
trap 'cleanup; printf "\033[H\033[2J"; exit 0' INT TERM
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
    opencode-go) printf 'OpenCode Go' ;;
    anthropic) printf 'Anthropic' ;;
    openai) printf 'OpenAI' ;;
    google) printf 'Google' ;;
    xai) printf 'xAI' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Fetches into USAGE_TMP, animating a spinner on the terminal while it runs.
# Writes only to the terminal, never to the JSON: stdout stays clean.
fetch_usage() {
  [[ -n $USAGE_TMP ]] || return 1
  local pid key frame i=0
  : > "$USAGE_TMP"
  "$OMP_BIN" usage --json > "$USAGE_TMP" 2>/dev/null &
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

  if ! command -v "$OMP_BIN" > /dev/null 2>&1; then
    printf '  %s not found on PATH\n' "$OMP_BIN"
    return
  fi
  if ! command -v jq > /dev/null 2>&1; then
    printf '  jq not found on PATH\n'
    return
  fi

  fetch_usage
  (( QUIT )) && return

  local json
  json=$(< "$USAGE_TMP")
  if [[ -z $json ]]; then
    printf '  usage unavailable — `%s usage --json` failed\n' "$OMP_BIN"
    return
  fi

  local rows
  rows=$(printf '%s' "$json" | jq -r '
    def token:
      if . == "monthly" then "mo"
      elif . == null or . == "" then "?"
      else . end;
    .reports[]?
    | .provider as $p
    | ((.metadata // {}).planType // "") as $plan
    | ((.metadata // {}).email // "") as $email
    | .limits[]?
    | [
        $p,
        $plan,
        $email,
        ((.scope.windowId // "?") | token)
          + (if (.scope.modelId // null) then "/" + .scope.modelId else "" end),
        ((.amount.usedFraction // 0) * 100 | floor),
        ((.window.resetsAt // 0) / 1000 | floor)
      ]
    | map(tostring) | join("\u001f")')

  if [[ -z $rows ]]; then
    printf '  no usage reports\n'
    return
  fi

  local now provider plan email window pct resets head reset last=''
  now=$(date +%s)
  while IFS=$'\x1f' read -r provider plan email window pct resets; do
    if [[ $provider != "$last" ]]; then
      [[ -n $last ]] && printf '\n'
      head=$(pretty_provider "$provider")
      [[ -n $plan ]] && head+=" · $plan"
      [[ -n $email ]] && head+=" · $email"
      printf '%s\n' "$head"
      last=$provider
    fi
    reset=''
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
