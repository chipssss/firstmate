#!/usr/bin/env python3
"""Feishu/Lark <-> firstmate inbox bridge (contrib example).

In:  captain's DMs to the firstmate bot -> bin/fm-inbox.sh note --request-id <message_id>
Out: fm-inbox replies to those notes  -> reply in the original Feishu message thread

Only messages from FEISHU_CAPTAIN_OPEN_ID in a p2p chat are accepted; everything else is ignored.
Config (env): FM_HOME (firstmate home), FEISHU_PROFILE (lark-cli profile of the bot app),
FEISHU_CAPTAIN_OPEN_ID (the captain's open_id in that app), FEISHU_ACK_TEXT (optional receipt text).
Run it under launchd/systemd with KeepAlive; see com.firstmate.feishu-bridge.plist.example.
Note: `lark-cli event consume` exits on stdin EOF, so the child keeps an open stdin pipe.
"""
import json, os, subprocess, sys, threading, time
from pathlib import Path

HOME = Path(os.environ["FM_HOME"])
PROFILE = os.environ["FEISHU_PROFILE"]
CAPTAIN_OPEN_ID = os.environ["FEISHU_CAPTAIN_OPEN_ID"]
ACK_TEXT = os.environ.get("FEISHU_ACK_TEXT", "Received; handed to firstmate.")
INBOX = str(HOME / "bin" / "fm-inbox.sh")
STATE = HOME / "state" / "feishu-bridge.reply-cursor"
POLL_S = 15
ENV = dict(os.environ, FM_HOME=str(HOME))


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def lark(*args):
    return subprocess.run(["lark-cli", *args, "--profile", PROFILE, "--as", "bot"],
                          capture_output=True, text=True, timeout=60)


def reply(message_id, text):
    r = lark("im", "+messages-reply", "--message-id", message_id, "--markdown", text)
    ok = r.returncode == 0 and '"ok": true' in r.stdout
    log("reply", message_id, "ok" if ok else "FAILED " + (r.stdout + r.stderr)[-300:])
    return ok


def text_of(ev):
    c = ev.get("content") or ""
    if ev.get("message_type") == "text":
        return c
    return f"[{ev.get('message_type')}] {c}"


def consume():
    while True:
        p = subprocess.Popen(["lark-cli", "event", "consume", "im.message.receive_v1",
                              "--profile", PROFILE, "--as", "bot", "--quiet"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        # consume exits on stdin EOF; launchd gives /dev/null, so hold an open pipe.
        log("listening, pid", p.pid)
        for line in p.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            mid = ev.get("message_id")
            if ev.get("chat_type") != "p2p" or ev.get("sender_id") != CAPTAIN_OPEN_ID or not mid:
                log("ignored", ev.get("chat_type"), ev.get("sender_id"))
                continue
            body = f"[feishu message_id={mid}] {text_of(ev)}"
            r = subprocess.run([INBOX, "note", "--request-id", mid, "--json", "--", body],
                               capture_output=True, text=True, env=ENV)
            log("note", mid, r.returncode, r.stdout.strip()[-200:])
            if r.returncode == 0 and '"replay"' not in r.stdout:
                reply(mid, ACK_TEXT)
        log("consumer exited rc", p.wait(), "- restarting in 5s")
        time.sleep(5)


def deliver_replies():
    cursor = STATE.read_text().strip() if STATE.exists() else ""
    while True:
        try:
            args = [INBOX, "receipts", "--all-replies", "--all-pending", "--all-handled"]
            if cursor:
                args += ["--after", cursor]
            d = json.loads(subprocess.run(args, capture_output=True, text=True, env=ENV).stdout)
            rid = {n["id"]: n.get("request_id") for n in d.get("pending", []) + d.get("handled", [])}
            for rep in d.get("replies", []):
                mid = rid.get(rep["id"])
                if mid and mid.startswith("om_") and not reply(mid, rep["body"]):
                    break  # retry this one next round, keep order
                cursor = rep["cursor"]
                STATE.write_text(cursor)
        except Exception as e:  # keep the bridge alive; log and retry
            log("reply loop error", e)
        time.sleep(POLL_S)


if __name__ == "__main__":
    threading.Thread(target=deliver_replies, daemon=True).start()
    consume()
