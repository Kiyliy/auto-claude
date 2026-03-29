#!/usr/bin/env python3
"""
Auto-Claude Runner — GOAL.md 驱动的自主迭代引擎

两种使用方式：
  1. 无头模式 (-p): python3 runner.py --project ~/myapp
  2. 交互模式: 用户在项目目录运行 claude，hooks 自动生效

本脚本用于无头模式：读取 GOAL.md → 启动 CC stream-json → 自动续命 → TG 消息桥接
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
    p.add_argument("--log", default=os.path.expanduser("~/auto-claude-test.log"), help="Log file path")
    return p.parse_args()

# ---------------------------------------------------------------------------
# Globals (set in main)
# ---------------------------------------------------------------------------
SESSION_ID = str(uuid.uuid4())
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

def daemon_request(method, path, timeout=5):
    """Unix socket HTTP request to daemon with chunked decoding"""
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(ARGS.socket)
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
        body = b""
        parts = raw.split(b"\r\n")
        i = 0
        while i < len(parts):
            try:
                size = int(parts[i], 16)
                if size == 0:
                    break
                body += parts[i+1][:size]
                i += 2
            except Exception:
                body += parts[i]
                i += 1
        return json.loads(body)
    except Exception:
        return None

def make_msg(text, priority="next"):
    return (json.dumps({
        "type": "user",
        "message": {"role": "user", "content": text},
        "priority": priority,
    }, ensure_ascii=False) + "\n").encode("utf-8")

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
    delta = ""
    if len(totals) >= 2:
        diff = totals[-1] - totals[-2]
        delta = f" ({'+' if diff >= 0 else ''}{diff})"
    return (
        f"上一轮评分：总分 {latest.get('total', '?')}/100{delta}\n"
        f"各维度：{scores_str}\n"
        f"趋势：{trend_line}\n"
        f"最低维度：{', '.join(worst)}\n"
        f"优先改进最低维度。"
    )

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global ARGS
    ARGS = parse_args()

    project_dir = os.path.abspath(os.path.expanduser(ARGS.project))
    if not os.path.isdir(project_dir):
        print(f"ERROR: project directory not found: {project_dir}", file=sys.stderr)
        sys.exit(1)

    # Ensure .auto-claude dir exists in project
    os.makedirs(os.path.join(project_dir, ".auto-claude"), exist_ok=True)

    # Read GOAL.md
    goal_content = read_goal(project_dir, ARGS.goal)
    initial_prompt = f"请阅读并遵循以下项目目标文件，开始工作。\n\n{goal_content}"

    os.environ["CLAUDE_SESSION_ID"] = SESSION_ID
    os.environ["IS_SANDBOX"] = "1"

    log(f"Started session={SESSION_ID}")
    log(f"Project: {project_dir}")
    log(f"Goal: {ARGS.goal}")
    notify(f"开始 (GOAL驱动) session={SESSION_ID}", "start")

    cmd = [
        "claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        "--session-id", SESSION_ID,
    ]
    if ARGS.mcp_config and os.path.isfile(ARGS.mcp_config):
        cmd += ["--mcp-config", ARGS.mcp_config]

    log("Starting CC process...")
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=project_dir,
    )
    log(f"pid={proc.pid}")

    # Send initial prompt
    proc.stdin.write(make_msg(initial_prompt))
    proc.stdin.flush()
    log("Initial prompt sent (GOAL.md)")

    turn_count = 0
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
                        inject = f"[Telegram 消息来自 {user}]: {text}\n请用 reply tool 回复。chat_id={msg.get('chat_id', '')}"
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
                notify(f"心跳：{idle:.0f}s 无活动", "warning")
                try:
                    proc.stdin.write(make_msg("继续工作。", "now"))
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

                if turn_count >= ARGS.max_turns:
                    log(f"Max turns ({ARGS.max_turns}) reached, stopping")
                    notify(f"达到最大轮次 ({ARGS.max_turns})", "max_reached")
                    break

                notify(f"Turn {turn_count} 完成", "continue")
                time.sleep(2)

                # Build trend-aware continuation message
                trend = read_trend(project_dir)
                continue_msg = f"继续改进项目。第 {turn_count} 轮。\n\n{trend}\n\n每完成一批改动后 git commit。"

                if proc.poll() is None:
                    proc.stdin.write(make_msg(continue_msg))
                    proc.stdin.flush()

    except Exception as e:
        log(f"Error: {e}")
    finally:
        alive = False
        log(f"Finished. Turns={turn_count}")
        notify(f"结束，共 {turn_count} 轮", "complete")

if __name__ == "__main__":
    main()
