# Feishu/Lark inbox bridge (contrib example)

Lets the captain talk to firstmate from Feishu/Lark direct messages.

- In: a DM from the captain to the bot becomes `bin/fm-inbox.sh note --request-id <message_id>`, and the bot replies with a short receipt.
- Out: `bin/fm-inbox.sh reply <note-id> <text>` is posted back in the original message thread.

Messages from anyone else, or from group chats, are ignored.

## Setup

1. Install `lark-cli` and log in a profile for a bot app that can receive `im.message.receive_v1` events and send messages.
2. Find the captain's `open_id` in that app.
3. Copy `com.firstmate.feishu-bridge.plist.example`, fill in the paths, profile and open_id, and load it with launchd (or run `bridge.py` under any supervisor with restart-on-exit).

`lark-cli event consume` exits when its stdin closes, and launchd gives children `/dev/null`, so `bridge.py` keeps an open stdin pipe to the consumer and restarts it if it exits.

The reply cursor is kept in `$FM_HOME/state/feishu-bridge.reply-cursor`, so restarts do not resend replies.
