#!/bin/bash
set -euo pipefail

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_path="$asset_dir/claude-hook-sessions.json"
transcript_path="$asset_dir/transcript.jsonl"
fake_claude="$asset_dir/fake-claude.sh"
session_id="pr8546-dev-verification"

cmux_bin="${CMUX_BUNDLED_CLI_PATH:-}"
if [[ -z "$cmux_bin" || ! -x "$cmux_bin" ]]; then
  cmux_bin="$(command -v cmux)"
fi

run_hook() {
  local event="$1"
  local source="${2:-}"
  local payload
  if [[ -n "$source" ]]; then
    payload="$(printf '{\"session_id\":\"%s\",\"source\":\"%s\",\"cwd\":\"%s\",\"transcript_path\":\"%s\",\"hook_event_name\":\"SessionStart\"}' \
      "$session_id" "$source" "$asset_dir" "$transcript_path")"
  else
    payload="$(printf '{\"session_id\":\"%s\",\"cwd\":\"%s\",\"transcript_path\":\"%s\",\"hook_event_name\":\"Stop\"}' \
      "$session_id" "$asset_dir" "$transcript_path")"
  fi
  printf '%s' "$payload" | env \
    CMUX_CLAUDE_HOOK_STATE_PATH="$state_path" \
    CMUX_CUSTOM_CLAUDE_PATH="$fake_claude" \
    "$cmux_bin" hooks claude "$event"
}

compact_and_reconcile() {
  # Claude refreshes its process-level terminal title around compaction. Keep
  # this reset visible briefly so the dev build has to repair the projection.
  printf '\033]0;Claude Code\007'
  /bin/echo "SIMULATED_COMPACTION_TITLE_RESET"
  /bin/sleep 2
  run_hook session-start compact
  run_hook auto-name
  /bin/echo "COMPACTION_RECONCILIATION_COMPLETE"
}

case "${1:-}" in
  setup)
    run_hook session-start startup
    run_hook auto-name
    /bin/echo "AUTO_TITLE_READY"
    ;;
  compact)
    compact_and_reconcile
    ;;
  manual)
    "$cmux_bin" workspace rename --workspace "${CMUX_WORKSPACE_ID:?}" --title "Manual Project"
    /bin/echo "MANUAL_WORKSPACE_TITLE_READY"
    compact_and_reconcile
    ;;
  *)
    /bin/echo "usage: dogfood.sh setup|compact|manual" >&2
    exit 2
    ;;
esac
