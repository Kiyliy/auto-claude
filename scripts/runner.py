#!/usr/bin/env python3
"""
Auto-Claude Runner v7 — stream-json + TG 消息桥接
TG 消息通过 daemon queue → polling → stdin 注入
"""

import subprocess
import json
import threading
import uuid
import os
import sys
import time
import socket as sock
import http.client

SESSION_ID = str(uuid.uuid4())
CWD = os.path.expanduser("~/projects/twitter-clone")
SOCKET_PATH = os.path.expanduser("~/.auto-claude/channel.sock")
LOG = os.path.expanduser("~/auto-claude-test.log")
MCP_CONFIG = os.path.expanduser("~/mcp-config.json")

INITIAL_PROMPT = (
    "这是一个已有的推特克隆项目，请审视当前代码质量并持续改进。"
    "目标：达到生产级水平。重点关注：测试覆盖率、安全性、错误处理、"
    "用户体验、响应式设计、文档完整性。在现有基础上改进。"
    "做完一项继续下一项。"
)

os.environ["CLAUDE_SESSION_ID"] = SESSION_ID
os.environ["IS_SANDBOX"] = "1"

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    line = f"[{ts} UTC] {msg}"
    print(line, flush=True)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except:
        pass

def notify(message, event_type="info"):
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(5)
        s.connect(SOCKET_PATH)
        payload = json.dumps({"message": message, "event_type": event_type, "session_id": SESSION_ID})
        req = f"POST /notify HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n{payload}"
        s.sendall(req.encode())
        s.recv(1024)
        s.close()
    except:
        pass

def daemon_request(method, path, timeout=5):
    """Unix socket HTTP request to daemon with chunked decoding"""
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(SOCKET_PATH)
        req = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        s.sendall(req.encode())
        data = b""
        while True:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            except:
                break
        s.close()
        raw = data.split(b"\r\n\r\n", 1)[-1]
        # dechunk
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
            except:
                body += parts[i]
                i += 1
        return json.loads(body)
    except:
        return None

def make_msg(text, priority="next"):
    return (json.dumps({
        "type": "user",
        "message": {"role": "user", "content": text},
        "priority": priority,
    }, ensure_ascii=False) + "\n").encode("utf-8")

def main():
    log(f"Started session={SESSION_ID}")
    notify(f"开始 (stream-json+TG桥接) session={SESSION_ID}", "start")

    cmd = [
        "claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--dangerously-skip-permissions",
        "--session-id", SESSION_ID,
    ]
    if os.path.isfile(MCP_CONFIG):
        cmd += ["--mcp-config", MCP_CONFIG]

    log(f"Starting process...")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=CWD)
    log(f"pid={proc.pid}")

    # 发初始 prompt
    proc.stdin.write(make_msg(INITIAL_PROMPT))
    proc.stdin.flush()
    log("Initial prompt sent")

    turn_count = 0
    last_activity = time.time()
    alive = True

    def read_stderr():
        for raw in proc.stderr:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                log(f"stderr: {line[:150]}")

    threading.Thread(target=read_stderr, daemon=True).start()

    # TG 消息轮询线程：从 daemon queue 拉消息 → 写入 stdin
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
                        inject = f"[Telegram 消息来自 {user}]: {text}\n请用 reply tool 回复他。chat_id={msg.get('chat_id','')}"
                        log(f"TG inject: {user}: {text}")
                        try:
                            proc.stdin.write(make_msg(inject, "now"))
                            proc.stdin.flush()
                            last_activity = time.time()
                        except:
                            break
            except:
                pass
            time.sleep(3)

    threading.Thread(target=tg_poller, daemon=True).start()

    # 心跳
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
                except:
                    pass

    threading.Thread(target=heartbeat, daemon=True).start()

    # 读 stdout
    try:
        for raw_line in proc.stdout:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            last_activity = time.time()
            try:
                msg = json.loads(line)
            except:
                continue

            msg_type = msg.get("type", "")
            if msg_type == "assistant":
                for block in msg.get("message", {}).get("content", []):
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        log(f"CC: {block['text'][:150]}")
                    elif block.get("type") == "tool_use":
                        log(f"CC tool: {block.get('name','?')}")
            elif msg_type == "result":
                turn_count += 1
                log(f"Turn {turn_count} complete")
                notify(f"Turn {turn_count} 完成", "continue")
                time.sleep(2)
                if proc.poll() is None:
                    proc.stdin.write(make_msg("继续改进项目。"))
                    proc.stdin.flush()
    except Exception as e:
        log(f"Error: {e}")
    finally:
        alive = False
        log(f"Finished. Turns={turn_count}")
        notify(f"结束，共 {turn_count} 轮", "complete")

if __name__ == "__main__":
    main()
