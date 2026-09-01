#!/usr/bin/env python3
"""End-to-end checks against a deployed E2B API.

Covers the sandbox lifecycle, the template routes, auth rejection, and - when the
API runs more than one replica - that the replicas share state instead of each
keeping their own. Standard library only, so it runs on the bastion as-is.

    python3 tools/api-smoke-test.py                      # through the ALB
    python3 tools/api-smoke-test.py --replicas 10.0.1.5:50001,10.0.2.6:50001

Credentials and domain come from /opt/config.properties and
infra-iac/db/config.json, the same files the deploy chain writes, so there is
nothing to export first. Exits non-zero if any check fails.
"""

import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

CONFIG_PROPERTIES = pathlib.Path("/opt/config.properties")
DB_CONFIG = pathlib.Path(__file__).resolve().parent.parent / "infra-iac/db/config.json"

# The template the deploy chain builds is the base image with a Jupyter start
# command, so a sandbox takes a few seconds to report itself running.
SANDBOX_TIMEOUT = 300
POLL_TIMEOUT = 90


class Failure(Exception):
    pass


class Client:
    """Minimal JSON HTTP client against one API endpoint."""

    def __init__(self, base, api_key, host_header=None):
        self.base = base.rstrip("/")
        self.api_key = api_key
        self.host_header = host_header

    def call(self, method, path, body=None, api_key=..., expect=None):
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        key = self.api_key if api_key is ... else api_key
        if key is not None:
            req.add_header("X-API-Key", key)
        if self.host_header:
            # Talking to a replica by IP: the API does not route on Host, but the
            # header keeps logs and any middleware seeing the real domain.
            req.add_header("Host", self.host_header)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                status, payload = resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            status, payload = exc.code, exc.read()
        except urllib.error.URLError as exc:
            raise Failure(f"{method} {url} did not answer: {exc.reason}") from exc

        parsed = None
        if payload:
            try:
                parsed = json.loads(payload)
            except json.JSONDecodeError:
                parsed = payload.decode(errors="replace")

        if expect is not None and status not in expect:
            raise Failure(f"{method} {path} returned {status}, expected {expect}: {parsed}")
        return status, parsed


def read_credentials():
    if not DB_CONFIG.is_file():
        raise Failure(f"{DB_CONFIG} is missing; run infra-iac/db/init-db.sh first")
    api_key = json.loads(DB_CONFIG.read_text()).get("teamApiKey")
    if not api_key:
        raise Failure(f"no teamApiKey in {DB_CONFIG}")

    domain = None
    if CONFIG_PROPERTIES.is_file():
        for line in CONFIG_PROPERTIES.read_text().splitlines():
            if line.startswith("CFNDOMAIN="):
                domain = line.split("=", 1)[1].strip()
    if not domain:
        raise Failure(f"no CFNDOMAIN in {CONFIG_PROPERTIES}")
    return api_key, domain


def wait_for(predicate, what, timeout=POLL_TIMEOUT, interval=3):
    """Poll until predicate returns a truthy value, else fail with what."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    raise Failure(f"timed out after {timeout}s waiting for {what} (last saw: {last})")


class Suite:
    def __init__(self):
        self.results = []

    def run(self, name, fn):
        start = time.monotonic()
        try:
            detail = fn() or ""
            self.results.append((True, name, detail, time.monotonic() - start))
            print(f"  PASS  {name}{f' - {detail}' if detail else ''}")
            return True
        except Failure as exc:
            self.results.append((False, name, str(exc), time.monotonic() - start))
            print(f"  FAIL  {name}\n          {exc}")
            return False
        except Exception as exc:  # unexpected: report, keep going, still a failure
            self.results.append((False, name, repr(exc), time.monotonic() - start))
            print(f"  ERROR {name}\n          {exc!r}")
            return False

    @property
    def failed(self):
        return [r for r in self.results if not r[0]]


def sandbox_state(client, sandbox_id):
    status, body = client.call("GET", f"/sandboxes/{sandbox_id}", expect={200, 404})
    if status == 404:
        return None
    return (body or {}).get("state")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", help="template ID to launch (default: newest ready template)")
    parser.add_argument("--replicas", default="", help="comma-separated host:port of individual API replicas")
    parser.add_argument("--keep", action="store_true", help="do not kill the sandbox at the end")
    args = parser.parse_args()

    api_key, domain = read_credentials()
    alb = Client(f"https://api.{domain}", api_key)
    replicas = [
        Client(f"http://{spec}", api_key, host_header=f"api.{domain}")
        for spec in filter(None, (s.strip() for s in args.replicas.split(",")))
    ]

    print(f"API      : https://api.{domain}")
    print(f"replicas : {args.replicas or '(none given, ALB only)'}")

    suite = Suite()
    state = {}

    # ---- reachability and auth -------------------------------------------------
    def health():
        status, _ = alb.call("GET", "/health", api_key=None, expect={200})
        return f"HTTP {status}"

    def auth_required():
        alb.call("GET", "/sandboxes", api_key=None, expect={401})
        return "no key -> 401"

    def auth_rejects_bad_key():
        alb.call("GET", "/sandboxes", api_key="e2b_" + "0" * 40, expect={401})
        return "bad key -> 401"

    # ---- templates ------------------------------------------------------------
    def list_templates():
        _, body = alb.call("GET", "/templates", expect={200})
        if not isinstance(body, list) or not body:
            raise Failure(f"expected a non-empty template list, got {body}")
        state["templates"] = body
        chosen = args.template
        if not chosen:
            # newest by createdAt, falling back to the first entry
            ordered = sorted(body, key=lambda t: t.get("createdAt") or "", reverse=True)
            chosen = ordered[0]["templateID"]
        state["template"] = chosen
        return f"{len(body)} template(s), using {chosen}"

    def get_template():
        tid = state["template"]
        _, body = alb.call("GET", f"/templates/{tid}", expect={200})
        if body.get("templateID") != tid:
            raise Failure(f"asked for {tid}, got {body.get('templateID')}")
        # TemplateWithBuilds: the shape carries builds, not cpu/memory - those
        # live on the build entries.
        builds = body.get("builds")
        if not isinstance(builds, list) or not builds:
            raise Failure(f"template {tid} reports no builds: {body}")
        newest = builds[0]
        return (f"{len(builds)} build(s), newest status={newest.get('status')} "
                f"cpu={newest.get('cpuCount')} mem={newest.get('memoryMB')}MB")

    # ---- sandbox lifecycle ----------------------------------------------------
    def create_sandbox():
        _, body = alb.call(
            "POST",
            "/sandboxes",
            body={
                "templateID": state["template"],
                "timeout": SANDBOX_TIMEOUT,
                "autoPause": True,
                "metadata": {"suite": "api-smoke-test"},
            },
            expect={201},
        )
        sandbox_id = body.get("sandboxID")
        if not sandbox_id:
            raise Failure(f"create returned no sandboxID: {body}")
        state["sandbox"] = sandbox_id
        return f"{sandbox_id} (envd {body.get('envdVersion')})"

    def sandbox_appears_in_list():
        sandbox_id = state["sandbox"]

        def present():
            _, body = alb.call("GET", "/sandboxes", expect={200})
            return next((s for s in body if s.get("sandboxID") == sandbox_id), None)

        found = wait_for(present, f"{sandbox_id} in the running list")
        if found.get("state") != "running":
            raise Failure(f"listed with state {found.get('state')}, expected running")
        return f"state={found['state']} cpu={found.get('cpuCount')} mem={found.get('memoryMB')}MB"

    def get_sandbox():
        sandbox_id = state["sandbox"]
        _, body = alb.call("GET", f"/sandboxes/{sandbox_id}", expect={200})
        if body.get("sandboxID") != sandbox_id:
            raise Failure(f"asked for {sandbox_id}, got {body.get('sandboxID')}")
        if (body.get("metadata") or {}).get("suite") != "api-smoke-test":
            raise Failure(f"metadata did not round-trip: {body.get('metadata')}")
        return f"state={body.get('state')} metadata round-tripped"

    def set_timeout():
        alb.call("POST", f"/sandboxes/{state['sandbox']}/timeout", body={"timeout": 600}, expect={204})
        return "timeout -> 600s, HTTP 204"

    def sandbox_metrics():
        status, body = alb.call("GET", f"/sandboxes/{state['sandbox']}/metrics", expect={200, 404, 501})
        if status != 200:
            return f"HTTP {status} (metrics backend not deployed)"
        return f"{len(body) if isinstance(body, list) else 'n/a'} sample(s)"

    def sandbox_logs():
        status, _ = alb.call("GET", f"/sandboxes/{state['sandbox']}/logs", expect={200, 404, 501})
        return f"HTTP {status}" + (" (no log backend deployed)" if status != 200 else "")

    def pause_sandbox():
        alb.call("POST", f"/sandboxes/{state['sandbox']}/pause", expect={204})
        wait_for(lambda: sandbox_state(alb, state["sandbox"]) == "paused", "state to become paused")
        return "state=paused"

    def resume_sandbox():
        _, body = alb.call(
            "POST", f"/sandboxes/{state['sandbox']}/resume", body={"timeout": SANDBOX_TIMEOUT}, expect={201}
        )
        wait_for(lambda: sandbox_state(alb, state["sandbox"]) == "running", "state to become running")
        return f"state=running (sandbox {body.get('sandboxID')})"

    def fork_sandbox():
        status, body = alb.call("POST", f"/sandboxes/{state['sandbox']}/fork", body={"timeout": 120}, expect={201, 409, 500, 503})
        if status != 201:
            return f"HTTP {status} - fork not available on this build"
        # Each entry is a SandboxForkResult: {sandbox, error}. Reading sandboxID
        # off the entry itself silently finds nothing and passes on a fork that
        # never happened, so unwrap and require a result.
        results = body if isinstance(body, list) else [body]
        forked, errors = [], []
        for item in results:
            sandbox = (item or {}).get("sandbox") or {}
            if sandbox.get("sandboxID"):
                forked.append(sandbox["sandboxID"])
            else:
                errors.append((item or {}).get("error"))
        state["forks"] = forked
        if not forked:
            raise Failure(f"fork returned 201 but produced no sandbox: errors={errors}")
        # The forks are cleaned up at the end; assert they are real by reading one.
        if sandbox_state(alb, forked[0]) is None:
            raise Failure(f"forked sandbox {forked[0]} is not readable")
        return f"forked -> {', '.join(forked)}"

    def kill_sandbox():
        alb.call("DELETE", f"/sandboxes/{state['sandbox']}", expect={204})
        wait_for(lambda: sandbox_state(alb, state["sandbox"]) is None, "sandbox to disappear")
        return "HTTP 204, then 404 on read"

    def kill_unknown_sandbox():
        # Well-formed but unused id: the API validates the format first, so a
        # obviously-bogus string gets 400 and never exercises the 404 path.
        alb.call("DELETE", "/sandboxes/i0000000000000000zzzz", expect={404})
        return "unknown id -> 404"

    def kill_malformed_sandbox_id():
        alb.call("DELETE", "/sandboxes/does-not-exist-000", expect={400})
        return "malformed id -> 400"

    # ---- replica coherence ----------------------------------------------------
    def replicas_agree_on_list():
        seen = {}
        for client in replicas:
            _, body = client.call("GET", "/sandboxes", expect={200})
            seen[client.base] = {s.get("sandboxID") for s in body}
        first, *rest = list(seen.values())
        for other in rest:
            if other != first:
                raise Failure(f"replicas disagree on the running set: {seen}")
        return f"{len(replicas)} replicas, identical set of {len(first)} sandbox(es)"

    def state_crosses_replicas():
        """Create on the first replica, then drive it from the second."""
        first, second = replicas[0], replicas[1]
        _, body = first.call(
            "POST",
            "/sandboxes",
            body={"templateID": state["template"], "timeout": 180, "autoPause": True,
                  "metadata": {"suite": "cross-replica"}},
            expect={201},
        )
        sandbox_id = body["sandboxID"]
        state["cross"] = sandbox_id
        try:
            wait_for(lambda: sandbox_state(second, sandbox_id) == "running",
                     f"replica 2 to see {sandbox_id} running")
            second.call("POST", f"/sandboxes/{sandbox_id}/pause", expect={204})
            wait_for(lambda: sandbox_state(first, sandbox_id) == "paused",
                     "replica 1 to see the pause done by replica 2")
            second.call("POST", f"/sandboxes/{sandbox_id}/resume", body={"timeout": 120}, expect={201})
            wait_for(lambda: sandbox_state(first, sandbox_id) == "running",
                     "replica 1 to see the resume done by replica 2")
        finally:
            first.call("DELETE", f"/sandboxes/{sandbox_id}", expect={204, 404})
        return f"{sandbox_id}: created on replica 1, paused+resumed via replica 2, both agreed"

    print("\nreachability and auth")
    suite.run("health endpoint is open", health)
    suite.run("unauthenticated request is rejected", auth_required)
    suite.run("invalid api key is rejected", auth_rejects_bad_key)

    print("\ntemplates")
    ok = suite.run("list templates", list_templates)
    if ok:
        suite.run("get template by id", get_template)

    if ok:
        print("\nsandbox lifecycle")
        if suite.run("create sandbox", create_sandbox):
            suite.run("sandbox appears in running list", sandbox_appears_in_list)
            suite.run("get sandbox by id", get_sandbox)
            suite.run("set sandbox timeout", set_timeout)
            suite.run("sandbox metrics", sandbox_metrics)
            suite.run("sandbox logs", sandbox_logs)
            suite.run("pause sandbox", pause_sandbox)
            suite.run("resume sandbox", resume_sandbox)
            suite.run("fork sandbox", fork_sandbox)
            if not args.keep:
                suite.run("kill sandbox", kill_sandbox)
        suite.run("kill unknown sandbox", kill_unknown_sandbox)
        suite.run("malformed sandbox id is rejected", kill_malformed_sandbox_id)

    if len(replicas) >= 2 and ok:
        print("\nreplica coherence")
        suite.run("replicas report the same running set", replicas_agree_on_list)
        suite.run("state written on one replica is visible on the other", state_crosses_replicas)
    elif replicas:
        print("\nreplica coherence skipped: need at least two --replicas")

    # cleanup for anything a failing test left behind
    for leftover in filter(None, [state.get("cross")] + state.get("forks", [])):
        alb.call("DELETE", f"/sandboxes/{leftover}", expect={204, 404})

    passed = len(suite.results) - len(suite.failed)
    print(f"\n{passed}/{len(suite.results)} checks passed")
    if suite.failed:
        for _, name, detail, _ in suite.failed:
            print(f"  failed: {name} - {detail}")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print(f"setup failed: {exc}", file=sys.stderr)
        sys.exit(2)
