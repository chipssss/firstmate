#!/usr/bin/env bash
# fm-push-monitor.sh - push-only supervision for a Claude Code primary: wake firstmate only when a worker
# or one of its PRs needs handling. Runs persistently under Claude Code's Monitor tool, which notifies the
# primary once per stdout line, so every event is printed as exactly one line:
#   - a new status line: done, blocked, needs-decision, failed, or a paused line
#     waiting on the captain's review/approval (routine working/paused/resolved ignored);
#   - a new captain inbox note (e.g. from a chat bridge) not yet seen by this monitor;
#   - a worker pane (Rex) that is gone, or idle with an unchanged screen for
#     STALL_SECS while its last status is not a terminal/declared wait;
#   - a GitHub PR named in a live task's status log that changes state (merged,
#     closed) or whose checks turn red or all-green, polled every PR_SECS.
# The agy "[0] Skip" survey that blocks a pane is dismissed automatically.
# While it runs it refreshes state/.push-monitor.beat; with config/push-monitor present and a fresh beat,
# the Claude Stop hooks (fm-claude-stop-autoarm.sh, fm-turnend-guard.sh) stand aside, and they resume
# their ordinary watcher supervision as soon as the beat goes stale.
# --once exits after the first event (legacy one-shot use); --baseline marks current state as read.
# Usage: FM_HOME=<home> [REX_SESSION=<id>] [STALL_SECS=900] [PR_SECS=300] bin/fm-push-monitor.sh [--once|--baseline]
# See docs/push-monitor.md.
set -u
HOME_DIR="${FM_HOME:?set FM_HOME to the firstmate home}"
STATE="$HOME_DIR/state"
SEEN="$STATE/.push-monitor.seen"
PANE="$STATE/.push-monitor.panes"
PRS="$STATE/.push-monitor.prs"
BEAT="$STATE/.push-monitor.beat"
INBOX_SEEN="$STATE/.push-monitor.inbox"
STALL_SECS=${STALL_SECS:-900}
PR_SECS=${PR_SECS:-300}
SESSION=${REX_SESSION:-}
ONCE=0
touch "$SEEN" "$PANE" "$PRS" "$INBOX_SEEN"
count() { wc -l < "$1" | tr -d ' '; }
kv_get() { awk -v k="$2" -F'\t' '$1==k{v=$0} END{print v}' "$1"; }
kv_set() { grep -v -F "$2	" "$1" > "$1.tmp" 2>/dev/null; printf '%s\n' "$3" >> "$1.tmp"; mv "$1.tmp" "$1"; }
seen_of() { kv_get "$SEEN" "$1" | cut -f2; }
mark() { kv_set "$SEEN" "$1" "$(printf '%s\t%s' "$1" "$2")"; }
# One event = one line, so the Monitor tool delivers it as one notification.
emit() {
  printf '%s\n' "$*" | tr '\n\t' '  ' | cut -c1-600; printf '\n'
  [ "$ONCE" = 1 ] && exit 0
  return 0
}
waits_on_captain='^paused .*((^|[^p])review|captain|approv|批准|复看)'

case "${1:-}" in
  --baseline)
    for f in "$STATE"/*.status; do [ -f "$f" ] && mark "$f" "$(count "$f")"; done
    for n in "$STATE"/inbox/*.note; do [ -f "$n" ] && basename "$n" .note >> "$INBOX_SEEN"; done
    echo "baselined"; exit 0 ;;
  --once) ONCE=1 ;;
  "") ;;
  *) echo "usage: fm-push-monitor.sh [--once|--baseline]" >&2; exit 2 ;;
esac

check_status() {
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    n=$(count "$f"); s=$(seen_of "$f"); s=${s:-0}
    [ "$n" -gt "$s" ] || continue
    hits=$(tail -n "$((n - s))" "$f" | grep -E "^(done|blocked|needs-decision|failed)( |\[|:)|$waits_on_captain" || true)
    mark "$f" "$n"
    [ -n "$hits" ] && emit "worker-stop: $(basename "$f" .status): $(printf '%s' "$hits" | tail -1 | cut -c1-400)"
  done
}

check_inbox() {
  for n in "$STATE"/inbox/*.note; do
    [ -f "$n" ] || continue
    id=$(basename "$n" .note)
    grep -qxF "$id" "$INBOX_SEEN" && continue
    echo "$id" >> "$INBOX_SEEN"
    emit "captain-inbox: $id: $(sed -n '/^--$/,$p' "$n" | sed 1d | head -5 | cut -c1-300)"
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
    if ! cap=$(rex block capture -s "$SESSION" -b "$blk" 2>/dev/null); then
      emit "worker-pane-gone: $id ($blk); last status: $(printf '%s' "$last" | cut -c1-300)"
      continue
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
      emit "worker-stalled: $id idle ${age}s with no screen change and no status update; last status: $(printf '%s' "$last" | cut -c1-300)"
    fi
  done
}

# PR digest: state plus a coarse check verdict (red / pending / green).
pr_digest() {
  # shellcheck disable=SC2016 # jq program, not shell expansion.
  gh pr view "$1" --json state,statusCheckRollup --jq '
    .state + " " + (
      [.statusCheckRollup[]? | (.conclusion // .state // "") | ascii_upcase] as $c
      | if ($c | map(select(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED")) | length) > 0 then "red"
        elif ($c | map(select(. == "" or . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED")) | length) > 0 then "pending"
        else "green" end)' 2>/dev/null
}

LAST_PR=0
check_prs() {
  command -v gh >/dev/null 2>&1 || return 0
  now=$(date +%s)
  [ $(( now - LAST_PR )) -ge "$PR_SECS" ] || return 0
  LAST_PR=$now
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    id=$(basename "$m" .meta)
    # shellcheck disable=SC2013 # URLs contain no spaces.
    for url in $(grep -o -E 'https://github\.com/[^/ ]+/[^/ ]+/pull/[0-9]+' "$STATE/$id.status" 2>/dev/null | sort -u); do
      d=$(pr_digest "$url"); [ -n "$d" ] || continue
      old=$(kv_get "$PRS" "$url" | cut -f2)
      [ "$d" = "$old" ] && continue
      kv_set "$PRS" "$url" "$(printf '%s\t%s' "$url" "$d")"
      # A first sighting only records the baseline unless it is already worth attention.
      if [ -z "$old" ]; then
        case "$d" in OPEN\ red) ;; *) continue ;; esac
      fi
      case "$d" in
        "OPEN pending") continue ;;
        *) emit "pr-change: $id: $url $old -> $d" ;;
      esac
    done
  done
}

while :; do
  touch "$BEAT"
  check_status
  check_inbox
  check_panes
  check_prs
  sleep 30
done
