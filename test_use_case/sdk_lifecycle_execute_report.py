#!/usr/bin/env python3

import importlib.metadata
import json
import os
import shlex
import sys
import time
import traceback
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from e2b import Sandbox
from e2b.sandbox.commands.command_handle import CommandExitException


DEFAULT_TEMPLATE_ID = "ohsi4lcgsz9318hkmo70"
PAUSE_TIMEOUT_SEC = 60
PAUSE_POLL_TIMEOUT_SEC = 180
PAUSE_POLL_INTERVAL_SEC = 10
RESUME_STABILIZATION_SEC = int(os.environ.get("RESUME_STABILIZATION_SEC", "5"))


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(event: str, **fields) -> None:
    payload = {"ts": now_iso(), "event": event, **fields}
    print(json.dumps(payload, ensure_ascii=True), flush=True)


def error_payload(exc: Exception) -> dict:
    return {
        "type": type(exc).__name__,
        "message": str(exc),
        "traceback_tail": traceback.format_exc().strip().splitlines()[-8:],
    }


def sandbox_info_payload(info) -> dict:
    redacted = {}
    for key in (
        "sandbox_id",
        "template_id",
        "name",
        "metadata",
        "started_at",
        "end_at",
        "state",
        "cpu_count",
        "memory_mb",
        "envd_version",
    ):
        value = getattr(info, key, None)
        redacted[key] = str(value) if key in {"started_at", "end_at", "state"} else value

    return redacted


class Reporter:
    def __init__(self) -> None:
        self.results = []

    def add(self, name: str, status: str, **details) -> None:
        self.results.append(
            {
                "name": name,
                "status": status,
                "recorded_at": now_iso(),
                **details,
            }
        )

    def summary(self) -> dict:
        summary = {"PASS": 0, "FAIL": 0, "WARN": 0}
        for item in self.results:
            summary[item["status"]] = summary.get(item["status"], 0) + 1
        return summary


def http_json(method: str, url: str, api_key: str, body: dict | None = None) -> tuple[int, object]:
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()

    req = urllib.request.Request(url, method=method, data=payload)
    req.add_header("X-API-Key", api_key)
    if body is not None:
        req.add_header("Content-Type", "application/json")

    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode()
        if not raw:
            return resp.getcode(), None
        return resp.getcode(), json.loads(raw)


def list_sandboxes(api_base: str, api_key: str, state: str) -> list[dict]:
    _, body = http_json("GET", f"{api_base}/v2/sandboxes?state={state}&limit=1000", api_key)
    return body


def delete_sandbox(api_base: str, api_key: str, sandbox_id: str) -> dict:
    req = urllib.request.Request(f"{api_base}/sandboxes/{sandbox_id}", method="DELETE")
    req.add_header("X-API-Key", api_key)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return {"ok": True, "status": resp.getcode(), "body": resp.read().decode()}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "status": exc.code, "body": exc.read().decode()}
    except Exception as exc:  # pragma: no cover - best effort cleanup
        return {"ok": False, "status": None, "body": f"{type(exc).__name__}: {exc}"}


def wait_for_state(api_base: str, api_key: str, sandbox_id: str, state: str) -> tuple[dict | None, int]:
    deadline = time.time() + PAUSE_POLL_TIMEOUT_SEC
    polls = 0
    while time.time() < deadline:
        polls += 1
        items = list_sandboxes(api_base, api_key, state)
        match = next((item for item in items if item.get("sandboxID") == sandbox_id), None)
        log("poll_state", desired_state=state, sandbox_id=sandbox_id, poll=polls, found=bool(match))
        if match:
            return match, polls
        time.sleep(PAUSE_POLL_INTERVAL_SEC)

    return None, polls


def main() -> int:
    api_key = os.environ.get("E2B_API_KEY")
    domain = os.environ.get("E2B_DOMAIN")
    template_id = os.environ.get("TEMPLATE_ID", DEFAULT_TEMPLATE_ID)

    if not api_key or not domain:
        print("E2B_API_KEY and E2B_DOMAIN must be set", file=sys.stderr)
        return 2

    api_base = f"https://api.{domain}"
    reporter = Reporter()

    final_report = {
        "generated_at": now_iso(),
        "sdk_version": importlib.metadata.version("e2b"),
        "domain": domain,
        "template_id": template_id,
        "python": sys.version,
        "tests": reporter.results,
    }

    sandbox = None
    short_id = None
    full_id = None
    persist_content = f"persist-{int(time.time())}"
    bg_pid = None
    lines_before_pause = None
    native_connect_ok = False
    workaround_connect_ok = False

    try:
        metadata = {
            "purpose": "sdk-lifecycle-execute",
            "createdAt": str(int(time.time())),
        }
        sandbox = Sandbox.beta_create(
            template=template_id,
            timeout=120,
            auto_pause=True,
            metadata=metadata,
            api_key=api_key,
            domain=domain,
        )
        short_id = sandbox.sandbox_id
        final_report["sandbox_id"] = short_id
        reporter.add("create", "PASS", sandbox_id=short_id, metadata=metadata)
        log("sandbox_created", sandbox_id=short_id)

        try:
            running = sandbox.is_running()
            reporter.add("is_running", "PASS" if running else "FAIL", value=running)
        except Exception as exc:
            reporter.add("is_running", "FAIL", error=error_payload(exc))

        try:
            sandbox.set_timeout(PAUSE_TIMEOUT_SEC, api_key=api_key, domain=domain)
            reporter.add("set_timeout", "PASS", timeout=PAUSE_TIMEOUT_SEC)
        except Exception as exc:
            reporter.add("set_timeout", "FAIL", timeout=PAUSE_TIMEOUT_SEC, error=error_payload(exc))

        try:
            info = sandbox.get_info(api_key=api_key, domain=domain)
            reporter.add("get_info_running", "PASS", info=sandbox_info_payload(info))
        except Exception as exc:
            reporter.add("get_info_running", "WARN", error=error_payload(exc))

        try:
            result = sandbox.commands.run("printf 'hello-sdk'")
            reporter.add(
                "execute_basic",
                "PASS" if result.exit_code == 0 and result.stdout == "hello-sdk" else "FAIL",
                exit_code=result.exit_code,
                stdout=result.stdout,
                stderr=result.stderr,
            )
        except Exception as exc:
            reporter.add("execute_basic", "FAIL", error=error_payload(exc))

        try:
            result = sandbox.commands.run("printf %s \"$TEST_ENV_VAR\"", envs={"TEST_ENV_VAR": "env-ok"})
            reporter.add(
                "execute_env",
                "PASS" if result.exit_code == 0 and result.stdout == "env-ok" else "FAIL",
                exit_code=result.exit_code,
                stdout=result.stdout,
                stderr=result.stderr,
            )
        except Exception as exc:
            reporter.add("execute_env", "FAIL", error=error_payload(exc))

        try:
            sandbox.commands.run("mkdir -p /tmp/sdk-cwd-check")
            result = sandbox.commands.run("pwd", cwd="/tmp/sdk-cwd-check")
            reporter.add(
                "execute_cwd",
                "PASS" if result.exit_code == 0 and result.stdout.strip() == "/tmp/sdk-cwd-check" else "FAIL",
                exit_code=result.exit_code,
                stdout=result.stdout,
                stderr=result.stderr,
            )
        except Exception as exc:
            reporter.add("execute_cwd", "FAIL", error=error_payload(exc))

        try:
            result = sandbox.commands.run("echo err-msg >&2; exit 7")
            reporter.add(
                "execute_nonzero_exit",
                "PASS" if result.exit_code == 7 and "err-msg" in result.stderr else "FAIL",
                exit_code=result.exit_code,
                stdout=result.stdout,
                stderr=result.stderr,
            )
        except CommandExitException as exc:
            reporter.add(
                "execute_nonzero_exit",
                "PASS" if exc.exit_code == 7 and "err-msg" in exc.stderr else "FAIL",
                exit_code=exc.exit_code,
                stdout=exc.stdout,
                stderr=exc.stderr,
                error=str(exc),
            )
        except Exception as exc:
            reporter.add("execute_nonzero_exit", "FAIL", error=error_payload(exc))

        try:
            sandbox.commands.run("sleep 3", timeout=1)
            reporter.add("execute_timeout", "FAIL", detail="expected timeout but command returned")
        except Exception as exc:
            reporter.add("execute_timeout", "PASS", error=error_payload(exc))

        try:
            sandbox.files.write("/tmp/lifecycle.txt", persist_content)
            read_back = sandbox.files.read("/tmp/lifecycle.txt")
            reporter.add(
                "filesystem_persist_file",
                "PASS" if read_back == persist_content else "FAIL",
                expected=persist_content,
                actual=read_back,
            )
        except Exception as exc:
            reporter.add("filesystem_persist_file", "FAIL", error=error_payload(exc))

        try:
            proc = sandbox.commands.run(
                "echo $$ > /tmp/loop.pid; while true; do date +%s >> /tmp/tick.log; sleep 2; done",
                background=True,
                timeout=0,
            )
            bg_pid = proc.pid
            proc.disconnect()
            time.sleep(5)
            lines_before_pause = int(sandbox.commands.run("wc -l < /tmp/tick.log").stdout.strip())
            reporter.add(
                "background_execute_and_disconnect",
                "PASS" if bg_pid and lines_before_pause >= 2 else "FAIL",
                pid=bg_pid,
                lines_before_pause=lines_before_pause,
            )
        except Exception as exc:
            reporter.add("background_execute_and_disconnect", "FAIL", error=error_payload(exc))

        paused_item, polls = wait_for_state(api_base, api_key, short_id, "paused")
        if paused_item:
            full_id = f"{short_id}-{paused_item.get('clientID')}"
            final_report["full_id"] = full_id
            reporter.add(
                "auto_pause",
                "PASS",
                polls=polls,
                paused_item=paused_item,
            )
        else:
            reporter.add("auto_pause", "FAIL", polls=polls)
            raise RuntimeError("sandbox did not enter paused state in time")

        log("resume_stabilization_wait", seconds=RESUME_STABILIZATION_SEC, sandbox_id=short_id)
        time.sleep(RESUME_STABILIZATION_SEC)

        try:
            sandbox.connect(timeout=300, api_key=api_key, domain=domain)
            native_connect_ok = True
            reporter.add("resume_native_connect", "PASS", wait_seconds=RESUME_STABILIZATION_SEC)
        except Exception as exc:
            reporter.add(
                "resume_native_connect",
                "FAIL",
                wait_seconds=RESUME_STABILIZATION_SEC,
                error=error_payload(exc),
            )

        if not native_connect_ok and full_id:
            try:
                setattr(sandbox, "_SandboxBase__sandbox_id", full_id)
                sandbox.connect(timeout=300, api_key=api_key, domain=domain)
                workaround_connect_ok = True
                reporter.add(
                    "resume_workaround_full_id",
                    "PASS",
                    full_id=full_id,
                    wait_seconds=RESUME_STABILIZATION_SEC,
                )
            except Exception as exc:
                reporter.add(
                    "resume_workaround_full_id",
                    "FAIL",
                    full_id=full_id,
                    wait_seconds=RESUME_STABILIZATION_SEC,
                    error=error_payload(exc),
                )

        if native_connect_ok or workaround_connect_ok:
            try:
                after_file = sandbox.files.read("/tmp/lifecycle.txt")
                after_pid = sandbox.commands.run("cat /tmp/loop.pid").stdout.strip()
                ps_result = sandbox.commands.run(
                    f"ps -p {shlex.quote(str(bg_pid))} -o pid=,comm=" if bg_pid else "true"
                )
                lines_after_first = int(sandbox.commands.run("wc -l < /tmp/tick.log").stdout.strip())
                time.sleep(4)
                lines_after_second = int(sandbox.commands.run("wc -l < /tmp/tick.log").stdout.strip())
                resume_exec = sandbox.commands.run("printf 'resume-ok'")
                reporter.add(
                    "post_resume_state_and_execute",
                    "PASS"
                    if (
                        after_file == persist_content
                        and str(after_pid) == str(bg_pid)
                        and lines_after_second > lines_after_first >= (lines_before_pause or 0)
                        and resume_exec.stdout == "resume-ok"
                    )
                    else "FAIL",
                    after_file=after_file,
                    expected_file=persist_content,
                    after_pid=after_pid,
                    expected_pid=bg_pid,
                    ps_stdout=ps_result.stdout,
                    ps_exit_code=ps_result.exit_code,
                    lines_before_pause=lines_before_pause,
                    lines_after_first=lines_after_first,
                    lines_after_second=lines_after_second,
                    resume_execute_stdout=resume_exec.stdout,
                )
            except Exception as exc:
                reporter.add("post_resume_state_and_execute", "FAIL", error=error_payload(exc))

        try:
            killed = sandbox.kill(api_key=api_key, domain=domain)
            reporter.add("kill", "PASS" if killed else "FAIL", result=killed)
        except Exception as exc:
            reporter.add("kill", "FAIL", error=error_payload(exc))

        try:
            absent = True
            for state in ("running", "paused"):
                items = list_sandboxes(api_base, api_key, state)
                if any(item.get("sandboxID") == short_id for item in items):
                    absent = False
            reporter.add("post_kill_absence_check", "PASS" if absent else "FAIL", absent=absent)
        except Exception as exc:
            reporter.add("post_kill_absence_check", "WARN", error=error_payload(exc))

    except Exception as exc:
        final_report["fatal_error"] = error_payload(exc)
    finally:
        if sandbox is not None:
            cleanup_attempts = []
            for candidate in [full_id, short_id]:
                if not candidate:
                    continue
                cleanup = delete_sandbox(api_base, api_key, candidate)
                cleanup_attempts.append({"sandbox_id": candidate, **cleanup})
                if cleanup["ok"] or cleanup.get("status") == 404:
                    break
            final_report["cleanup_attempts"] = cleanup_attempts

        final_report["summary"] = reporter.summary()
        final_report["native_connect_ok"] = native_connect_ok
        final_report["workaround_connect_ok"] = workaround_connect_ok
        final_report["tests"] = reporter.results

    print("FINAL_REPORT=" + json.dumps(final_report, ensure_ascii=True, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
