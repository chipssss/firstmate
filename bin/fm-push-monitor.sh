#!/usr/bin/env bash
# fm-push-monitor.sh - push-only supervision for a Claude Code primary: wake firstmate only when a worker needs
# handling. Runs as one Claude Code background task and exits (= notifies) on:
#   - a new status line: done, blocked, needs-decision, failed, or a paused line
#     waiting on the captain's review/approval (routine working/paused/resolved ignored);
#   - a new captain inbox note (e.g. from a chat bridge) not yet seen by this monitor;
#   - a worker pane (Rex) that is gone, or idle with an unchanged screen for
#     STALL_SECS while its last status is not a terminal/declared wait.
# The agy "[0] Skip" survey that blocks a pane is dismissed automatically.
# Re-run after handling. --baseline marks current status logs and inbox notes as read.
# Usage: FM_HOME=<home> [REX_SESSION=<id>] [STALL_SECS=900] bin/fm-push-monitor.sh [--baseline]
# See docs/push-monitor.md.
set -u
HOME_DIR="${FM_HOME:?set FM_HOME to the firstmate home}"
STATE="$HOME_DIR/state"
SEEN="$STATE/.push-monitor.seen"
PANE="$STATE/.push-monitor.panes"
STALL_SECS=${STALL_SECS:-900}
SESSION=${REX_SESSION:-}
touch "$SEEN" "$PANE"
INBOX_SEEN="$STATE/.push-monitor.inbox"; touch "$INBOX_SEEN"
count() { wc -l < "$1" | tr -d ' '; }
kv_get() { awk -v k="$2" -F'\t' '$1==k{v=$0} END{print v}' "$1"; }
kv_set() { grep -v -F "$2	" "$1" > "$1.tmp" 2>/dev/null; printf '%s\n' "$3" >> "$1.tmp"; mv "$1.tmp" "$1"; }
seen_of() { kv_get "$SEEN" "$1" | cut -f2; }
mark() { kv_set "$SEEN" "$1" "$(printf '%s\t%s' "$1" "$2")"; }
if [ "${1:-}" = "--baseline" ]; then
  for f in "$STATE"/*.status; do [ -f "$f" ] && mark "$f" "$(count "$f")"; done
  for n in "$STATE"/inbox/*.note; do [ -f "$n" ] && basename "$n" .note >> "$INBOX_SEEN"; done
  echo "baselined"; exit 0
fi

check_status() {
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    n=$(count "$f"); s=$(seen_of "$f"); s=${s:-0}
    [ "$n" -gt "$s" ] || continue
    hits=$(tail -n "$((n - s))" "$f" | grep -E '^(done|blocked|needs-decision|failed)( |\[|:)|^paused .*(review|captain|approv|批准|复看)' || true)
    mark "$f" "$n"
    if [ -n "$hits" ]; then
      echo "worker-stop: $(basename "$f" .status)"; echo "$hits" | cut -c1-400; exit 0
    fi
  done
}

INBOX_SEEN="$STATE/.push-monitor.inbox"
touch "$INBOX_SEEN"
check_inbox() {
  for n in "$STATE"/inbox/*.note; do
    [ -f "$n" ] || continue
    id=$(basename "$n" .note)
    grep -qxF "$id" "$INBOX_SEEN" && continue
    echo "$id" >> "$INBOX_SEEN"
    echo "captain-inbox: $id"; sed -n '/^--$/,$p' "$n" | sed 1d | head -5 | cut -c1-300
    exit 0
  done
}

check_panes() {
  [ -n "$SESSION" ] || return 0
  now=$(date +%s)
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    id=$(basename "$m" .meta)
    blk=$(grep -m1 '^rex_block_id=' "$m" | cut -d= -f2)
    [ -n "$blk" ] || continue
    last=$(tail -1 "$STATE/$id.status" 2>/dev/null)
    # Lanes already finished or waiting on the captain are not stalls.
    case "$last" in done*|needs-decision*|blocked*|failed*|paused*) continue;; esac
    printf '%s' "$last" | grep -q -E '^paused .*(review|captain|approv|批准|复看)' && continue
    if ! cap=$(rex block capture -s "$SESSION" -b "$blk" 2>/dev/null); then
      echo "worker-pane-gone: $id ($blk)"; echo "last status: $last" | cut -c1-300; exit 0
    fi
    tailtxt=$(printf '%s\n' "$cap" | grep -v '^\s*$' | tail -15)
    if printf '%s' "$tailtxt" | grep -q '\[0\] Skip'; then
      rex block send -s "$SESSION" -b "$blk" 0 >/dev/null 2>&1; continue
    fi
    # Busy markers: agy 'esc to cancel', Claude 'esc to interrupt'.
    if printf '%s' "$tailtxt" | grep -q -E 'esc to (cancel|interrupt)'; then busy=1; else busy=0; fi
    h=$(printf '%s' "$tailtxt" | shasum | cut -c1-16)
    prev=$(kv_get "$PANE" "$id")
    ph=$(printf '%s' "$prev" | cut -f2); pt=$(printf '%s' "$prev" | cut -f3); alerted=$(printf '%s' "$prev" | cut -f4)
    if [ "$h" != "$ph" ] || [ "$busy" = 1 ]; then
      kv_set "$PANE" "$id" "$(printf '%s\t%s\t%s\t0' "$id" "$h" "$now")"; continue
    fi
    age=$(( now - ${pt:-$now} ))
    if [ "$age" -ge "$STALL_SECS" ] && [ "${alerted:-0}" = 0 ]; then
      kv_set "$PANE" "$id" "$(printf '%s\t%s\t%s\t1' "$id" "$h" "$pt")"
      echo "worker-stalled: $id idle ${age}s with no screen change and no status update"
      echo "last status: $last" | cut -c1-300
      printf '%s\n' "$tailtxt" | tail -6 | cut -c1-200
      exit 0
    fi
  done
}

while :; do
  check_status
  check_inbox
  check_panes
  sleep 30
done
