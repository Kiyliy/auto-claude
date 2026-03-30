#!/usr/bin/env python3
"""
Auto-Claude Runner — headless (-p) mode engine

Usage:
  python3 runner.py --project ~/myapp
  python3 runner.py --project ~/myapp --resume
"""

import argparse
import subprocess
import json
import threading
import uuid
import os
import sys
import time
import socket as sock


def parse_args():
    p = argparse.ArgumentParser(description="Auto-Claude runner")
    p.add_argument("--project", required=True, help="Project directory (must contain GOAL.md)")
    p.add_argument("--goal", default="GOAL.md", help="Goal file name (default: GOAL.md)")
    p.add_argument("--max-turns", type=int, default=100, help="Max turns (default: 100)")
    p.add_argument("--socket", default=os.path.expanduser("~/.auto-claude/channel.sock"))
    p.add_argument("--log", default=None, help="Log file (default: PROJECT/.auto-claude/runner.log)")
    p.add_argument("--session-id", default=None, help="Reuse specific session ID")
    p.add_argument("--resume", action="store_true", help="Resume last session")
    return p.parse_args()


ARGS = None
SESSION_ID = None


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    line = f"[{ts} UTC] {msg}"
    print(line, flush=True)
    if ARGS and ARGS.log:
        try:
            with open(ARGS.log, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass


def daemon_request(method, path, body=None, timeout=5):
    """Unix socket HTTP request to TG daemon."""
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(ARGS.socket)
        if body:
            req = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}"
        else:
            req = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        s.sendall(req.encode())
        data = b""
        while True:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            except Exception:
                break
        s.close()
        # Parse chunked HTTP response
        raw = data.split(b"\r\n\r\n", 1)[-1]
        body_bytes = b""
        parts = raw.split(b"\r\n")
        i = 0
        while i < len(parts):
            try:
                size = int(parts[i], 16)
                if size == 0:
                    break
                body_bytes += parts[i + 1][:size]
                i += 2
            except Exception:
                body_bytes += parts[i]
                i += 1
        return json.loads(body_bytes)
    except Exception:
        return None


def notify(message, event_type="info"):
    try:
        payload = json.dumps({"message": message, "event_type": event_type, "session_id": SESSION_ID})
        daemon_request("POST", "/notify", payload)
    except Exception:
        pass


def make_msg(text):
    return (json.dumps({
        "type": "user",
        "message": {"role": "user", "content": text},
    }, ensure_ascii=False) + "\n").encode("utf-8")


# --- Session persistence ---

def session_file(project_dir):
    return os.path.join(project_dir, ".auto-claude", "session.json")


def save_session(project_dir, sid, turn_count=0):
    path = session_file(project_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump({"session_id": sid, "turn_count": turn_count,
                    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f)


def load_session(project_dir):
    path = session_file(project_dir)
    if os.path.isfile(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            pass
    return None


def read_goal(project_dir, goal_file):
    goal_path = os.path.join(project_dir, goal_file)
    if not os.path.isfile(goal_path):
        print(f"ERROR: {goal_path} not found", file=sys.stderr)
        sys.exit(1)
    with open(goal_path, encoding="utf-8") as f:
        return f.read()


# --- Main ---

def main():
    global ARGS, SESSION_ID
    ARGS = parse_args()

    project_dir = os.path.abspath(os.path.expanduser(ARGS.project))
    if not os.path.isdir(project_dir):
        print(f"ERROR: {project_dir} not found", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.join(project_dir, ".auto-claude"), exist_ok=True)
    if ARGS.log is None:
        ARGS.log = os.path.join(project_dir, ".auto-claude", "runner.log")

    # Session ID
    is_resume = False
    if ARGS.session_id:
        SESSION_ID = ARGS.session_id
    elif ARGS.resume:
        prev = load_session(project_dir)
        if prev:
            SESSION_ID = prev["session_id"]
            is_resume = True
            log(f"Resuming session {SESSION_ID}")
        else:
            SESSION_ID = str(uuid.uuid4())
    else:
        SESSION_ID = str(uuid.uuid4())

    goal_content = read_goal(project_dir, ARGS.goal)
    log(f"Session={SESSION_ID[:8]} ({'resume' if is_resume else 'new'}) Project={project_dir}")

    # Register with TG daemon
    resp = daemon_request("POST", "/sessions",
                          json.dumps({"session_id": SESSION_ID, "name": f"AC: {os.path.basename(project_dir)}"}))
    if resp and resp.get("ok"):
        log(f"TG topic={resp.get('topic_thread_id', 'none')}")

    notify(f"{'Resumed' if is_resume else 'Started'} {SESSION_ID[:8]}", "start")

    # Build CC command
    cmd = ["claude", "-p",
           "--input-format", "stream-json",
           "--output-format", "stream-json",
           "--verbose",
           "--dangerously-skip-permissions"]
    if is_resume:
        cmd += ["--resume", SESSION_ID]
    else:
        cmd += ["--session-id", SESSION_ID]

    log(f"Starting CC...")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=project_dir)

    # Initial prompt
    if is_resume:
        prompt = "Continue working on the project. Read GOAL.md if you need context."
    else:
        prompt = f"Read and follow this project goal. Start working.\n\n{goal_content}"

    proc.stdin.write(make_msg(prompt))
    proc.stdin.flush()
    log("Prompt sent")

    turn_count = 0
    save_session(project_dir, SESSION_ID, turn_count)
    last_activity = time.time()
    alive = True

    # Stderr reader
    def read_stderr():
        for raw in proc.stderr:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                log(f"stderr: {line[:200]}")
    threading.Thread(target=read_stderr, daemon=True).start()

    # TG message poller — injects Telegram messages into CC stdin
    def tg_poller():
        nonlocal last_activity
        while alive and proc.poll() is None:
            try:
                resp = daemon_request("GET", f"/sessions/{SESSION_ID}/messages?timeout=5", timeout=10)
                if resp and resp.get("messages"):
                    for msg in resp["messages"]:
                        text = msg.get("text", "")
                        if not text:
                            continue
                        user = msg.get("user", "?")
                        inject = f"[Telegram from {user}]: {text}"
                        log(f"TG inject: {user}: {text}")
                        try:
                            proc.stdin.write(make_msg(inject))
                            proc.stdin.flush()
                            last_activity = time.time()
                        except Exception:
                            break
            except Exception:
                pass
            time.sleep(3)
    threading.Thread(target=tg_poller, daemon=True).start()

    # Read stdout (stream-json events)
    try:
        for raw_line in proc.stdout:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            last_activity = time.time()
            try:
                msg = json.loads(line)
            except Exception:
                continue

            msg_type = msg.get("type", "")

            if msg_type == "assistant":
                for block in msg.get("message", {}).get("content", []):
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        log(f"CC: {block['text'][:200]}")
                    elif block.get("type") == "tool_use":
                        log(f"CC tool: {block.get('name', '?')}")

            elif msg_type == "result":
                turn_count += 1
                save_session(project_dir, SESSION_ID, turn_count)
                log(f"Turn {turn_count} complete")
                notify(f"Turn {turn_count} done", "turn")

                if turn_count >= ARGS.max_turns:
                    log(f"Max turns ({ARGS.max_turns}) reached")
                    notify(f"Max turns reached", "max_reached")
                    break

                # No continuation message needed — the Stop hook handles it.
                # If the hook blocks (ok=false), CC continues automatically.
                # If the hook allows (ok=true), CC stops and we get no more events.

    except Exception as e:
        log(f"Error: {e}")
    finally:
        alive = False
        save_session(project_dir, SESSION_ID, turn_count)
        log(f"Finished. Turns={turn_count}")
        notify(f"Done, {turn_count} turns", "complete")


if __name__ == "__main__":
    main()
