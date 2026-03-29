#!/usr/bin/env python3
import json
import pathlib
import subprocess
import time
import urllib.parse
import urllib.request

BASE = pathlib.Path("/srv/openclaw-manager")
TOK_DIR = BASE / "tokens"

TOKEN = (TOK_DIR / "control-bot.token").read_text().strip()
ADMIN_ID = int((TOK_DIR / "your_telegram_user_id.txt").read_text().strip())
OFFSET_FILE = TOK_DIR / "control-bot.offset"
USED_FILE = TOK_DIR / "used_tokens.tsv"

def api(method, data=None):
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    if data is None:
        req = urllib.request.Request(url)
    else:
        body = urllib.parse.urlencode(data).encode()
        req = urllib.request.Request(url, data=body)
    with urllib.request.urlopen(req, timeout=70) as resp:
        return json.load(resp)

def send(chat_id, text):
    api("sendMessage", {"chat_id": str(chat_id), "text": text})

def load_offset():
    if OFFSET_FILE.exists():
        raw = OFFSET_FILE.read_text().strip()
        if raw:
            return int(raw)
    return None

def save_offset(offset):
    OFFSET_FILE.write_text(str(offset))

def run_cmd(args):
    return subprocess.run(args, text=True, capture_output=True)

def lookup_project_bot(name: str):
    if not USED_FILE.exists():
        return None
    for line in USED_FILE.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) >= 4 and parts[1] == name:
            return parts[2]
    return None

def list_projects_with_bots():
    proc = run_cmd(["incus", "list", "--format", "json"])
    if proc.returncode != 0:
        return None, "failed to list projects"
    items = json.loads(proc.stdout)
    names = sorted(
        x["name"]
        for x in items
        if x["name"].startswith("project-")
    )
    rows = []
    for name in names:
        bot = lookup_project_bot(name) or "(no bot)"
        rows.append(f"{name} -> {bot}")
    return rows, None

def main():
    try:
        api("deleteWebhook", {"drop_pending_updates": "true"})
    except Exception:
        pass

    offset = load_offset()

    while True:
        try:
            payload = {"timeout": 50}
            if offset is not None:
                payload["offset"] = str(offset)

            data = api("getUpdates", payload)

            for update in data.get("result", []):
                offset = int(update["update_id"]) + 1
                save_offset(offset)

                msg = update.get("message") or {}
                text = (msg.get("text") or "").strip()
                chat = msg.get("chat") or {}
                sender = msg.get("from") or {}
                chat_id = chat.get("id")
                from_id = sender.get("id")

                if chat.get("type") != "private" or from_id != ADMIN_ID:
                    continue

                if text == "/start":
                    send(
                        chat_id,
                        "ready\n"
                        "use:\n"
                        "/new_project project-a\n"
                        "/delete_project project-a\n"
                        "/project_info project-a\n"
                        "/add_token <telegram_bot_token>\n"
                        "/list_projects"
                    )
                    continue

                if text.startswith("/new_project "):
                    name = text.split(None, 1)[1].strip()
                    send(chat_id, f"creating: {name}\nthis can take a bit...")
                    proc = run_cmd(["/srv/openclaw-manager/scripts/oc-new-project.sh", name])

                    if proc.returncode == 0:
                        bot_username = lookup_project_bot(name)
                        if not bot_username:
                            bot_username = proc.stdout.strip() or "(created but bot lookup failed)"
                        send(
                            chat_id,
                            f"created: {name}\n"
                            f"bot: {bot_username}\n"
                            f"workspace: /srv/openclaw-manager/projects/{name}/workspace"
                        )
                    else:
                        err = (proc.stderr or proc.stdout or "unknown error")[-3500:]
                        send(chat_id, f"failed:\n{err}")
                    continue

                if text.startswith("/delete_project "):
                    name = text.split(None, 1)[1].strip()
                    send(chat_id, f"deleting: {name}")
                    proc = run_cmd(["/srv/openclaw-manager/scripts/oc-delete-project.sh", name])
                    if proc.returncode == 0:
                        send(chat_id, proc.stdout.strip())
                    else:
                        err = (proc.stderr or proc.stdout or "unknown error")[-3500:]
                        send(chat_id, f"failed:\n{err}")
                    continue

                if text.startswith("/project_info "):
                    name = text.split(None, 1)[1].strip()
                    bot = lookup_project_bot(name)
                    if bot:
                        send(
                            chat_id,
                            f"project: {name}\n"
                            f"bot: {bot}\n"
                            f"workspace: /srv/openclaw-manager/projects/{name}/workspace"
                        )
                    else:
                        send(chat_id, f"project not found or no bot recorded: {name}")
                    continue

                if text.startswith("/add_token "):
                    token = text.split(None, 1)[1].strip()
                    proc = run_cmd(["/srv/openclaw-manager/scripts/oc-add-token.sh", token])
                    if proc.returncode == 0:
                        send(chat_id, f"added token for {proc.stdout.strip()}")
                    else:
                        err = (proc.stderr or proc.stdout or "unknown error")[-3500:]
                        send(chat_id, f"failed:\n{err}")
                    continue

                if text == "/list_projects":
                    rows, err = list_projects_with_bots()
                    if err:
                        send(chat_id, err)
                    elif rows:
                        send(chat_id, "projects:\n" + "\n".join(rows))
                    else:
                        send(chat_id, "no projects")
                    continue

                send(chat_id, "unknown command\nuse /start")
        except Exception as e:
            time.sleep(3)

if __name__ == "__main__":
    main()
