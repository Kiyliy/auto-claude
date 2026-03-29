#!/usr/bin/env python3
"""
Auto-Claude Runner — GOAL.md-driven autonomous iteration engine

Usage:
  # First run (creates new session):
  python3 runner.py --project ~/myapp

  # Resume existing session:
  python3 runner.py --project ~/myapp --resume

  # Force specific session ID:
  python3 runner.py --project ~/myapp --session-id abc123
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
    p = argparse.ArgumentParser(description="Auto-Claude: GOAL.md-driven autonomous iteration")
    p.add_argument("--project", required=True, help="Project directory (must contain GOAL.md)")
    p.add_argument("--goal", default="GOAL.md", help="Goal file name (default: GOAL.md)")
    p.add_argument("--max-turns", type=int, default=100, help="Max rounds (default: 100)")
    p.add_argument("--socket", default=os.path.expanduser("~/.auto-claude/channel.sock"), help="Daemon socket path")
    p.add_argument("--mcp-config", default=None, help="MCP config file path")
    p.add_argument("--log", default=None, help="Log file path (default: PROJECT/.auto-claude/runner.log)")
    p.add_argument("--session-id", default=None, help="Reuse specific session ID")
    p.add_argument("--resume", action="store_true", help="Resume last session from this project")
    return p.parse_args()

# ---------------------------------------------------------------------------
# Globals (set in main)
# ---------------------------------------------------------------------------
SESSION_ID = None
ARGS = None

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    line = f"[{ts} UTC] {msg}"
    print(line, flush=True)
    try:
        with open(ARGS.log, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass

def notify(message, event_type="info"):
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(5)
        s.connect(ARGS.socket)
        payload = json.dumps({"message": message, "event_type": event_type, "session_id": SESSION_ID})
        req = f"POST /notify HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n{payload}"
        s.sendall(req.encode())
        s.recv(1024)
        s.close()
    except Exception:
        pass

def daemon_request(method, path, body=None, timeout=5):
    """Unix socket HTTP request to daemon with chunked decoding"""
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
        raw = data.split(b"\r\n\r\n", 1)[-1]
        body_bytes = b""
        parts = raw.split(b"\r\n")
        i = 0
        while i < len(parts):
            try:
                size = int(parts[i], 16)
                if size == 0:
                    break
                body_bytes += parts[i+1][:size]
                i += 2
            except Exception:
                body_bytes += parts[i]
                i += 1
        return json.loads(body_bytes)
    except Exception:
        return None

def make_msg(text, priority="next"):
    return (json.dumps({
        "type": "user",
        "message": {"role": "user", "content": text},
        "priority": priority,
    }, ensure_ascii=False) + "\n").encode("utf-8")

# ---------------------------------------------------------------------------
# Session Persistence
# ---------------------------------------------------------------------------

def session_file(project_dir):
    return os.path.join(project_dir, ".auto-claude", "session.json")

def save_session(project_dir, sid, turn_count=0):
    data = {"session_id": sid, "turn_count": turn_count, "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    with open(session_file(project_dir), "w") as f:
        json.dump(data, f)

def load_session(project_dir):
    path = session_file(project_dir)
    if os.path.isfile(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            pass
    return None

# ---------------------------------------------------------------------------
# GOAL.md + Results
# ---------------------------------------------------------------------------

def read_goal(project_dir, goal_file):
    goal_path = os.path.join(project_dir, goal_file)
    if not os.path.isfile(goal_path):
        print(f"ERROR: {goal_path} not found", file=sys.stderr)
        sys.exit(1)
    with open(goal_path, encoding="utf-8") as f:
        return f.read()

def read_trend(project_dir, last_n=5):
    """Read last N entries from results.jsonl and build trend summary"""
    results_file = os.path.join(project_dir, ".auto-claude", "results.jsonl")
    if not os.path.isfile(results_file):
        return ""
    try:
        with open(results_file, encoding="utf-8") as f:
            lines = f.readlines()
        lines = [l.strip() for l in lines if l.strip()][-last_n:]
        entries = [json.loads(l) for l in lines]
    except Exception:
        return ""
    if not entries:
        return ""
    latest = entries[-1]
    scores = latest.get("scores", {})
    scores_str = ", ".join(f"{k}({v})" for k, v in scores.items())
    totals = [e.get("total", 0) for e in entries]
    trend_line = " → ".join(str(t) for t in totals)
    worst = latest.get("worst", [])
    bugs = latest.get("bugs_found", [])
    delta = ""
    if len(totals) >= 2:
        diff = totals[-1] - totals[-2]
        delta = f" ({'+' if diff >= 0 else ''}{diff})"
    result = (
        f"Last score: {latest.get('total', '?')}/100{delta}\n"
        f"Dimensions: {scores_str}\n"
        f"Trend: {trend_line}\n"
        f"Lowest: {', '.join(worst)}"
    )
    if bugs:
        result += f"\nBugs found last round: {len(bugs)}"
        for b in bugs[:3]:
            result += f"\n  - {b}"
    return result

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global ARGS, SESSION_ID
    ARGS = parse_args()

    project_dir = os.path.abspath(os.path.expanduser(ARGS.project))
    if not os.path.isdir(project_dir):
        print(f"ERROR: project directory not found: {project_dir}", file=sys.stderr)
        sys.exit(1)

    # Default log to project .auto-claude dir
    if ARGS.log is None:
        ARGS.log = os.path.join(project_dir, ".auto-claude", "runner.log")

    # Ensure .auto-claude dir exists in project
    os.makedirs(os.path.join(project_dir, ".auto-claude"), exist_ok=True)

    # --- Session ID resolution ---
    is_resume = False
    if ARGS.session_id:
        SESSION_ID = ARGS.session_id
    elif ARGS.resume:
        prev = load_session(project_dir)
        if prev:
            SESSION_ID = prev["session_id"]
            is_resume = True
            log(f"Resuming session={SESSION_ID} (turn_count was {prev.get('turn_count', 0)})")
        else:
            SESSION_ID = str(uuid.uuid4())
            log("No previous session found, starting new")
    else:
        SESSION_ID = str(uuid.uuid4())

    # Read GOAL.md
    goal_content = read_goal(project_dir, ARGS.goal)

    os.environ["CLAUDE_SESSION_ID"] = SESSION_ID
    os.environ["IS_SANDBOX"] = "1"

    log(f"Session={SESSION_ID} ({'resume' if is_resume else 'new'})")
    log(f"Project: {project_dir}")
    log(f"Goal: {ARGS.goal}")

    # Register session with daemon (creates TG topic — idempotent if already exists)
    register_payload = json.dumps({"session_id": SESSION_ID, "name": f"AC: {os.path.basename(project_dir)}"})
    resp = daemon_request("POST", "/sessions", register_payload)
    if resp and resp.get("ok"):
        log(f"Session registered (topic={resp.get('topic_thread_id', 'none')})")
    else:
        log("Daemon not available, skipping session registration")

    notify(f"{'Resumed' if is_resume else 'Started'} session={SESSION_ID[:8]}", "start")

    # Build CC command
    cmd = [
        "claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
    ]
    if is_resume:
        cmd += ["--resume", SESSION_ID]
    else:
        cmd += ["--session-id", SESSION_ID]
    if ARGS.mcp_config and os.path.isfile(ARGS.mcp_config):
        cmd += ["--mcp-config", ARGS.mcp_config]

    log(f"Starting CC ({'--resume' if is_resume else '--session-id'})...")
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=project_dir,
    )
    log(f"pid={proc.pid}")

    # Build initial/continuation prompt
    if is_resume:
        trend = read_trend(project_dir)
        initial_prompt = f"Continue working on the project. Read GOAL.md if you need to refresh context.\n\n{trend}"
    else:
        initial_prompt = f"Read and follow this project goal file. Start working.\n\n{goal_content}"

    proc.stdin.write(make_msg(initial_prompt))
    proc.stdin.flush()
    log(f"Prompt sent ({'trend-aware resume' if is_resume else 'GOAL.md initial'})")

    # Save session
    turn_count = 0
    save_session(project_dir, SESSION_ID, turn_count)

    last_activity = time.time()
    alive = True

    # Stderr reader
    def read_stderr():
        for raw in proc.stderr:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                log(f"stderr: {line[:150]}")
    threading.Thread(target=read_stderr, daemon=True).start()

    # TG message poller
    def tg_poller():
        nonlocal last_activity
        poll_path = f"/sessions/{SESSION_ID}/messages?timeout=5"
        while alive and proc.poll() is None:
            try:
                resp = daemon_request("GET", poll_path, timeout=10)
                if resp and resp.get("messages"):
                    for msg in resp["messages"]:
                        user = msg.get("user", "?")
                        text = msg.get("text", "")
                        if not text:
                            continue
                        inject = f"[Telegram message from {user}]: {text}\nReply using: curl -s --unix-socket ~/.auto-claude/channel.sock -X POST http://localhost/sessions/{SESSION_ID}/reply -H 'Content-Type: application/json' -d '{{\"text\":\"YOUR_REPLY\"}}'"
                        log(f"TG inject: {user}: {text}")
                        try:
                            proc.stdin.write(make_msg(inject, "now"))
                            proc.stdin.flush()
                            last_activity = time.time()
                        except Exception:
                            break
            except Exception:
                pass
            time.sleep(3)
    threading.Thread(target=tg_poller, daemon=True).start()

    # Heartbeat
    def heartbeat():
        nonlocal last_activity
        while alive and proc.poll() is None:
            time.sleep(60)
            idle = time.time() - last_activity
            if idle > 600:
                log(f"HEARTBEAT: idle {idle:.0f}s, sending wake")
                notify(f"Heartbeat: {idle:.0f}s idle", "warning")
                try:
                    proc.stdin.write(make_msg("Continue working.", "now"))
                    proc.stdin.flush()
                    last_activity = time.time()
                except Exception:
                    pass
    threading.Thread(target=heartbeat, daemon=True).start()

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
                        log(f"CC: {block['text'][:150]}")
                    elif block.get("type") == "tool_use":
                        log(f"CC tool: {block.get('name', '?')}")

            elif msg_type == "result":
                turn_count += 1
                log(f"Turn {turn_count} complete")
                save_session(project_dir, SESSION_ID, turn_count)

                if turn_count >= ARGS.max_turns:
                    log(f"Max turns ({ARGS.max_turns}) reached, stopping")
                    notify(f"Max turns ({ARGS.max_turns}) reached", "max_reached")
                    break

                notify(f"Turn {turn_count} complete", "continue")
                time.sleep(2)

                # Build trend-aware continuation message
                trend = read_trend(project_dir)
                continue_msg = f"Continue improving the project. Turn {turn_count}.\n\n{trend}\n\nPrioritize fixing the lowest-scoring dimensions and any bugs found."

                if proc.poll() is None:
                    proc.stdin.write(make_msg(continue_msg))
                    proc.stdin.flush()

    except Exception as e:
        log(f"Error: {e}")
    finally:
        alive = False
        save_session(project_dir, SESSION_ID, turn_count)
        log(f"Finished. Turns={turn_count}")
        notify(f"Finished, {turn_count} turns", "complete")

if __name__ == "__main__":
    main()
