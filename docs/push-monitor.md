# Push-only supervision for a Claude Code primary

This doc explains an optional way to supervise a fleet from a Claude Code primary without paying for periodic Stop-hook wakes.
It is for operators who find the Stop-hook watcher cycle and its follow-up turns too frequent or too token-heavy.

## What it does

`bin/fm-push-monitor.sh` runs persistently under Claude Code's Monitor tool, which notifies the primary once per stdout line.
It prints one line, and so wakes the primary, only when something needs firstmate:

- a new status line that is `done`, `blocked`, `needs-decision` or `failed`, or a `paused` line that waits on the captain's review or approval;
- a new captain inbox note (`state/inbox/*.note`), for example from a chat bridge;
- a worker Rex pane that is gone, or that shows the same screen for `STALL_SECS` (default 900) while its last status is not a finished state or a declared wait;
- a GitHub PR named in a live task's status log that merges, closes, turns red, or turns all-green, polled every `PR_SECS` (default 300).

It also dismisses the agy "[0] Skip" survey that otherwise blocks a worker pane.
Routine `working`, `resolved` and declared `paused` lines never wake the primary, and an idle fleet costs no tokens.

## Replacing the Stop-hook cycle

While it runs, the monitor refreshes `state/.push-monitor.beat` every 30 seconds.
When the home opts in with a local `config/push-monitor` file and that beat is fresh (within `FM_PUSH_MONITOR_GRACE`, default 120 seconds), `bin/fm-claude-stop-autoarm.sh` does not arm the watcher and `bin/fm-turnend-guard.sh` lets every turn end (`fm_push_monitor_owns` in `bin/fm-supervision-lib.sh`).
If the monitor dies, the beat goes stale and both hooks resume ordinary watcher supervision at the next turn end, so supervision never silently lapses.
To also stop the headless supervision host, add `config/supervision-host-off` ([configuration](configuration.md)).

## How to use it

1. Opt in: `touch "$FM_HOME/config/push-monitor"` (and optionally `config/supervision-host-off`).
2. Mark current state as read: `FM_HOME=<home> bin/fm-push-monitor.sh --baseline`.
3. Start it with the Monitor tool, persistent:

   ```sh
   FM_HOME=/path/to/home REX_SESSION="$REX_SESSION" bin/fm-push-monitor.sh
   ```

4. For each notification, handle the worker, note, or PR as the supervision contract says; the monitor keeps running.

`--once` keeps the legacy one-shot behavior: exit after the first event, for a `run_in_background` task that is re-run after each handling.
Its read cursors live in `state/.push-monitor.{seen,panes,inbox,prs}`.
Remove `config/push-monitor` to return to Stop-hook supervision.

## Limits

- It does not feed the durable wake queue; with the hooks standing aside, the watcher does not run, so wake-queue-only events (heartbeats, custom checks, Relay) are not watched.
- Pane stall detection needs Rex (`REX_SESSION` set and `rex_block_id=` in the task meta); without it only status, inbox, and PR events are watched.
- PR watching needs an authenticated `gh` and finds PRs only by URL in a live task's status log.
- A worker that stays busy but makes no progress keeps its screen changing, so it is not reported as stalled.
