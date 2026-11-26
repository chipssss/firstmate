# Push-only supervision for a Claude Code primary

This doc explains an optional way to supervise a fleet from a Claude Code primary without paying for periodic Stop-hook wakes.
It is for operators who stay in the session and find the per-wake follow-ups too frequent or too token-heavy.

## What it does

`bin/fm-push-monitor.sh` runs as one Claude Code background task (`run_in_background`).
It exits, which notifies the primary, only when something needs firstmate:

- a new status line that is `done`, `blocked`, `needs-decision` or `failed`, or a `paused` line that waits on the captain's review or approval;
- a new captain inbox note (`state/inbox/*.note`), for example from a chat bridge;
- a worker Rex pane that is gone, or that shows the same screen for `STALL_SECS` (default 900) while its last status is not a finished state or a declared wait.

It also dismisses the agy "[0] Skip" survey that otherwise blocks a worker pane.
Routine `working`, `resolved` and declared `paused` lines never wake the primary.

## How to use it

1. Enter quiet mode with `/quiet`, so routine Stop-hook follow-ups stop reaching the conversation.
2. Start the monitor as a Claude Code background task:

   ```sh
   FM_HOME=/path/to/home REX_SESSION="$REX_SESSION" bin/fm-push-monitor.sh
   ```

3. When it exits, read its output, handle the worker or note, drain and acknowledge the wake queue as usual, then start it again.
   It is one-shot by design: one notification per exit, re-armed after each handling.

`bin/fm-push-monitor.sh --baseline` marks every current status line and inbox note as already seen, for a fresh start.
Its read cursors live in `state/.push-monitor.{seen,panes,inbox}`.

## Limits

- It adds a push channel; it does not replace the wake queue. Drain and acknowledge wakes exactly as the supervision contract says.
- Pane stall detection needs Rex (`REX_SESSION` set and `rex_block_id=` in the task meta); without it only status and inbox events are watched.
- A worker that stays busy but makes no progress keeps its screen changing, so it is not reported as stalled; the heartbeat review still covers it.
