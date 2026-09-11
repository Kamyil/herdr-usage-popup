#!/usr/bin/env bash
# Claude Code statusLine sink.
#
# Claude Code pipes its session JSON to the configured statusLine command. That
# JSON carries `rate_limits` for subscriber accounts, which this script records
# so Usage Popup can render Claude Code without ever reading a credential file.
#
# It also prints a compact status line back to the Claude Code TUI.
set -uo pipefail

state_dir="${HERDR_USAGE_STATE_DIR:-${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-usage-popup}}"
snapshot="$state_dir/claude-statusline.json"

input=$(cat)
limits=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)

[[ -n $limits && $limits != null ]] || exit 0

if mkdir -p "$state_dir" 2>/dev/null; then
  tmp="$snapshot.$$"
  if printf '{"recordedAt":%s,"rateLimits":%s}\n' "$(date +%s)" "$limits" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$snapshot"
  else
    rm -f "$tmp"
  fi
fi

printf '%s' "$limits" | jq -r '
  [ (if .five_hour.used_percentage != null then "5h \(.five_hour.used_percentage | round)%" else empty end),
    (if .seven_day.used_percentage != null then "7d \(.seven_day.used_percentage | round)%" else empty end) ]
  | join(" · ")'
