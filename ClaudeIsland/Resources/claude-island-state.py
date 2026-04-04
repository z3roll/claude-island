#!/usr/bin/env python3
"""
Claude Island Hook
- Sends session state to ClaudeIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app
- For AskUserQuestion: waits for user answer from the app
"""
import json
import os
import socket
import sys
import time

SOCKET_PATH = "/tmp/claude-island.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
MAX_RETRIES = 3
RETRY_DELAY = 0.3  # seconds between retries

# Log to stderr so it doesn't interfere with hook output to stdout
def _log(msg):
    print(f"[claude-island-hook] {msg}", file=sys.stderr)


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def send_event(state, retries=MAX_RETRIES):
    """Send event to app with retry logic. Returns response if any."""
    needs_response = state.get("status") in ("waiting_for_approval", "waiting_for_answer")

    for attempt in range(1, retries + 1):
        sock = None
        try:
            # Check socket file exists before attempting connection
            if not os.path.exists(SOCKET_PATH):
                if attempt < retries:
                    _log(f"Socket not found at {SOCKET_PATH}, retry {attempt}/{retries}")
                    time.sleep(RETRY_DELAY)
                    continue
                else:
                    _log(f"Socket not found at {SOCKET_PATH} after {retries} attempts — is ClaudeIsland.app running?")
                    return None

            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(TIMEOUT_SECONDS if needs_response else 5)
            sock.connect(SOCKET_PATH)

            payload = json.dumps(state).encode()
            sock.sendall(payload)
            # Shut down the write side so the server sees EOF
            sock.shutdown(socket.SHUT_WR)

            # For permission requests and question answers, wait for response
            if needs_response:
                chunks = []
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    chunks.append(chunk)
                sock.close()
                sock = None
                if chunks:
                    return json.loads(b"".join(chunks).decode())
                return None
            else:
                sock.close()
                sock = None
                return None

        except (ConnectionRefusedError, FileNotFoundError) as e:
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass
            if attempt < retries:
                _log(f"Connection failed ({e}), retry {attempt}/{retries}")
                time.sleep(RETRY_DELAY)
            else:
                _log(f"Connection failed after {retries} attempts: {e}")
                return None

        except (socket.timeout, socket.error, OSError) as e:
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass
            _log(f"Socket error: {e}")
            return None

        except json.JSONDecodeError as e:
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass
            _log(f"Invalid JSON response: {e}")
            return None

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        tool_name = data.get("tool_name")
        state["tool"] = tool_name
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

        # AskUserQuestion: intercept and wait for user answer from the app
        if tool_name == "AskUserQuestion":
            state["status"] = "waiting_for_answer"

            # Send to app and wait for answer
            response = send_event(state)

            if response:
                answers = response.get("answers")
                if answers:
                    # Build updatedInput: echo back questions + add answers
                    updated_input = dict(tool_input)
                    updated_input["answers"] = answers
                    output = {
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "allow",
                            "updatedInput": updated_input,
                        }
                    }
                    print(json.dumps(output))
                    sys.exit(0)

            # No response or no answers - output empty JSON so Claude Code
            # falls through to its normal terminal UI gracefully
            print(json.dumps({}))
            sys.exit(0)
        else:
            state["status"] = "running_tool"

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via ClaudeIsland",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - usually means back to waiting
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"
        # Clean up statusLine cache file for this session
        tmpdir = os.environ.get("TMPDIR", "/tmp/")
        cache_file = os.path.join(tmpdir, f"claude-island-session-{session_id}.json")
        try:
            os.unlink(cache_file)
        except OSError:
            pass

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
