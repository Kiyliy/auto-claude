#!/usr/bin/env python3
"""
SleepShip Runner — headless (-p) mode engine with self-managed review loop.

Flow:
  CC works → result event → runner.py runs Sonnet review →
    score < 90 → inject feedback into CC stdin → CC continues
    score >= 90 → stop

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
import re
import socket as sock


def parse_args():
    p = argparse.ArgumentParser(description="SleepShip runner")
    p.add_argument("--project", required=True, help="Project directory (must contain GOAL.md)")
    p.add_argument("--goal", default="GOAL.md", help="Goal file name")
    p.add_argument("--max-turns", type=int, default=100, help="Max turns")
    p.add_argument("--review-model", default="claude-sonnet-4-6", help="Model for review")
    p.add_argument("--review-timeout", type=int, default=1800, help="Review timeout in seconds")
    p.add_argument("--target-score", type=int, default=90, help="Target score to pass")
    p.add_argument("--socket", default=os.path.expanduser("~/.sleepship/channel.sock"))
    p.add_argument("--session-id", default=None, help="Reuse specific session ID")
    p.add_argument("--resume", action="store_true", help="Resume last session")
    return p.parse_args()


ARGS = None
SESSION_ID = None


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    print(f"[{ts} UTC] {msg}", file=sys.stderr, flush=True)


# --- TG daemon communication ---

def daemon_request(method, path, body=None, timeout=5):
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


def tg_reply(text):
    try:
        payload = json.dumps({"text": text})
        daemon_request("POST", f"/sessions/{SESSION_ID}/reply", payload)
    except Exception:
        pass


def make_msg(text):
    return (json.dumps({
        "type": "user",
        "message": {"role": "user", "content": text},
    }, ensure_ascii=False) + "\n").encode("utf-8")


# --- Session persistence ---

def session_file(project_dir):
    return os.path.join(project_dir, ".sleepship", "session.json")


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


# --- Review ---

def run_review(project_dir):
    """Run independent Sonnet review. Returns (score, ok, reason, parsed_json)."""
    scoring = ""
    for f in ["scoring.md", "GOAL.md", "requirements.md"]:
        path = os.path.join(project_dir, f)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                scoring += f"\n\n=== {f} ===\n{fh.read()}"

    prompt = f"""You are working in {project_dir}.

{scoring}

Follow scoring.md strictly: start the server, curl-test endpoints, check code, score.
Output strict JSON:
{{"ok": true/false, "total": N, "scores": {{}}, "bugs": [...], "reason": "..."}}

ok=true only when total >= {ARGS.target_score}."""

    log(f"Starting review ({ARGS.review_model})...")

    try:
        result = subprocess.run(
            ["claude", "-p",
             "--model", ARGS.review_model,
             "--output-format", "stream-json",
             "--verbose",
             "--dangerously-skip-permissions",
             prompt],
            capture_output=True, text=True, timeout=ARGS.review_timeout,
            cwd=project_dir,
        )
        # Extract result text from stream-json
        review_text = ""
        for line in result.stdout.strip().split("\n"):
            try:
                d = json.loads(line)
                if d.get("type") == "result":
                    review_text = d.get("result", "")
                    break
            except Exception:
                continue

    except subprocess.TimeoutExpired:
        log("Review timed out")
        return 0, False, "review timed out", {}
    except Exception as e:
        log(f"Review error: {e}")
        return 0, False, f"review error: {e}", {}

    # Parse JSON from review text
    raw = review_text.strip()
    raw = re.sub(r"^```json\s*", "", raw)
    raw = re.sub(r"```\s*$", "", raw)
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        raw = raw[start:end + 1]

    try:
        parsed = json.loads(raw)
    except Exception:
        log(f"Review parse failed. Raw: {raw[:200]}")
        return 0, False, "parse failed", {"raw": raw[:500]}

    total = parsed.get("total", 0)
    ok = parsed.get("ok", False)
    reason = parsed.get("reason", "")
    log(f"Review: {total}/{ARGS.target_score} ok={ok}")
    return total, ok, reason, parsed


def save_review(project_dir, parsed):
    """Append review result to reviews.jsonl."""
    review_log = os.path.join(project_dir, ".sleepship", "reviews.jsonl")
    parsed["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    parsed["reviewer"] = ARGS.review_model
    try:
        with open(review_log, "a") as f:
            f.write(json.dumps(parsed, ensure_ascii=False) + "\n")
    except Exception:
        pass


# --- Main ---

def main():
    global ARGS, SESSION_ID
    ARGS = parse_args()

    project_dir = os.path.abspath(os.path.expanduser(ARGS.project))
    if not os.path.isdir(project_dir):
        print(f"ERROR: {project_dir} not found", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.join(project_dir, ".sleepship"), exist_ok=True)

    # Session ID
    is_resume = ARGS.resume
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

    # Build CC command — NO hooks, runner manages the loop
    cmd = ["claude", "-p",
           "--input-format", "stream-json",
           "--output-format", "stream-json",
           "--verbose",
           "--dangerously-skip-permissions"]
    if is_resume:
        cmd += ["--resume", SESSION_ID]
    else:
        cmd += ["--session-id", SESSION_ID]

    log("Starting CC...")
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
    last_assistant_text = ""
    alive = True

    # Raw stream-json log
    raw_log_path = os.path.join(project_dir, ".sleepship", f"{SESSION_ID}.log")
    raw_log = open(raw_log_path, "a")

    # Stderr reader
    def read_stderr():
        for raw in proc.stderr:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                log(f"stderr: {line[:200]}")
    threading.Thread(target=read_stderr, daemon=True).start()

    # TG message poller
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

    # Main event loop
    try:
        for raw_line in proc.stdout:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            last_activity = time.time()
            raw_log.write(line + "\n")
            raw_log.flush()

            try:
                msg = json.loads(line)
            except Exception:
                continue

            msg_type = msg.get("type", "")

            # Track last assistant text
            if msg_type == "assistant":
                for block in msg.get("message", {}).get("content", []):
                    if isinstance(block, dict) and block.get("type") == "text":
                        t = block["text"].strip()
                        if len(t) > 10:
                            last_assistant_text = t

            if msg_type == "result":
                turn_count += 1
                save_session(project_dir, SESSION_ID, turn_count)

                # Forward CC's last message to TG
                if last_assistant_text:
                    tg_reply(f"📋 Turn {turn_count}:\n\n{last_assistant_text[:2000]}")
                    last_assistant_text = ""

                if turn_count >= ARGS.max_turns:
                    notify(f"Max turns ({ARGS.max_turns}) reached", "max_reached")
                    break

                # --- Run independent review ---
                log(f"Turn {turn_count} done. Running review...")
                notify(f"Turn {turn_count} done, reviewing...", "review")

                total, ok, reason, parsed = run_review(project_dir)
                save_review(project_dir, parsed)

                # Send review result to TG
                tg_reply(f"🔍 Review: {total}/{ARGS.target_score}\n{'✅ PASS' if ok else '❌ FAIL'}\n\n{reason[:1500]}")

                if ok and total >= ARGS.target_score:
                    log(f"PASSED! Score {total} >= {ARGS.target_score}")
                    notify(f"PASSED! {total}/{ARGS.target_score}", "passed")
                    break

                # Inject review feedback into CC
                feedback = f"""Independent reviewer ({ARGS.review_model}) score: {total}/{ARGS.target_score}

{reason}

Continue improving the project based on this feedback. Fix bugs first, then improve the lowest-scoring dimensions."""

                log(f"Injecting feedback (score={total})...")
                try:
                    proc.stdin.write(make_msg(feedback))
                    proc.stdin.flush()
                except Exception:
                    log("Failed to inject feedback, CC may have exited")
                    break

    except Exception as e:
        log(f"Error: {e}")
    finally:
        alive = False
        raw_log.close()
        save_session(project_dir, SESSION_ID, turn_count)
        log(f"Finished. Turns={turn_count}")
        notify(f"Done, {turn_count} turns", "complete")


if __name__ == "__main__":
    main()
