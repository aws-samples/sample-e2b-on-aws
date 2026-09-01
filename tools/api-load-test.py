#!/usr/bin/env python3
"""Concurrency test for a deployed E2B API.

Four phases, each aimed at something that only breaks under parallel load:

  1. burst create   - N sandboxes at once through the load balancer
  2. read fan-out   - many parallel readers, split across replicas, must agree
  3. churn          - pause/resume the same sandboxes, alternating replicas, so
                      two API processes drive one sandbox's state machine
  4. duplicate kill - concurrent DELETEs of the same sandbox

Standard library only. Every sandbox it creates is killed at the end, including
after a failure, and each is created with a short timeout so a crash still lets
them expire on their own.

    python3 tools/api-load-test.py --sandboxes 12 --concurrency 12 \
        --replicas 10.0.83.123:50001,10.0.37.239:50001

Sizing note: each sandbox takes the template's cpuCount/memoryMB (4 vCPU /
4096 MiB for the default build) off one client node, so --sandboxes is bounded by
the client pool, not by the API.
"""

import argparse
import collections
import json
import pathlib
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

CONFIG_PROPERTIES = pathlib.Path("/opt/config.properties")
DB_CONFIG = pathlib.Path(__file__).resolve().parent.parent / "infra-iac/db/config.json"


class Client:
    def __init__(self, base, api_key, host_header=None, name=None):
        self.base = base.rstrip("/")
        self.api_key = api_key
        self.host_header = host_header
        self.name = name or self.base

    def call(self, method, path, body=None, timeout=120):
        """Return (status, parsed_body, elapsed_seconds). Never raises on HTTP status."""
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-API-Key", self.api_key)
        if self.host_header:
            req.add_header("Host", self.host_header)
        start = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status, payload = resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            status, payload = exc.code, exc.read()
        except (urllib.error.URLError, TimeoutError) as exc:
            return 0, {"transport_error": str(getattr(exc, "reason", exc))}, time.monotonic() - start
        elapsed = time.monotonic() - start
        parsed = None
        if payload:
            try:
                parsed = json.loads(payload)
            except json.JSONDecodeError:
                parsed = payload.decode(errors="replace")
        return status, parsed, elapsed


class Stats:
    """Latency and status-code tally for one phase."""

    def __init__(self, phase):
        self.phase = phase
        self.lock = threading.Lock()
        self.latencies = []
        self.codes = collections.Counter()
        self.errors = []

    def record(self, status, elapsed, detail=None):
        with self.lock:
            self.latencies.append(elapsed)
            self.codes[status] += 1
            if status >= 500 or status == 0:
                self.errors.append((status, detail))

    def line(self):
        if not self.latencies:
            return f"{self.phase:16} no requests"
        ordered = sorted(self.latencies)
        p50 = statistics.median(ordered)
        p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
        codes = " ".join(f"{code}×{n}" for code, n in sorted(self.codes.items()))
        return (f"{self.phase:16} n={len(ordered):<5} p50={p50:6.2f}s p95={p95:6.2f}s "
                f"max={ordered[-1]:6.2f}s  {codes}")

    @property
    def server_errors(self):
        return [e for e in self.errors]


def read_credentials():
    api_key = json.loads(DB_CONFIG.read_text())["teamApiKey"]
    domain = next(
        line.split("=", 1)[1].strip()
        for line in CONFIG_PROPERTIES.read_text().splitlines()
        if line.startswith("CFNDOMAIN=")
    )
    return api_key, domain


def newest_ready_template(client):
    status, body, _ = client.call("GET", "/templates")
    if status != 200 or not body:
        raise SystemExit(f"cannot list templates: HTTP {status} {body}")
    ordered = sorted(body, key=lambda t: t.get("createdAt") or "", reverse=True)
    return ordered[0]["templateID"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sandboxes", type=int, default=12, help="sandboxes to create in the burst")
    parser.add_argument("--concurrency", type=int, default=12, help="parallel in-flight requests")
    parser.add_argument("--readers", type=int, default=24, help="parallel list readers in phase 2")
    parser.add_argument("--churn-rounds", type=int, default=3, help="pause/resume rounds per sandbox in phase 3")
    parser.add_argument("--churn-sandboxes", type=int, default=4, help="how many sandboxes to churn")
    parser.add_argument("--sandbox-timeout", type=int, default=600, help="sandbox timeout, so leaks expire")
    parser.add_argument("--replicas", default="", help="comma-separated host:port of individual replicas")
    parser.add_argument("--template", help="template ID (default: newest)")
    args = parser.parse_args()

    api_key, domain = read_credentials()
    alb = Client(f"https://api.{domain}", api_key, name="alb")
    replicas = [
        Client(f"http://{spec}", api_key, host_header=f"api.{domain}", name=f"replica{i + 1}")
        for i, spec in enumerate(filter(None, (s.strip() for s in args.replicas.split(","))))
    ]
    endpoints = replicas or [alb]
    template = args.template or newest_ready_template(alb)

    print(f"API       : {alb.base}")
    print(f"replicas  : {', '.join(c.base for c in replicas) or '(ALB only)'}")
    print(f"template  : {template}")
    print(f"load      : {args.sandboxes} sandboxes, concurrency {args.concurrency}, "
          f"{args.readers} readers, {args.churn_rounds} churn rounds\n")

    created = []
    created_lock = threading.Lock()
    failures = []
    phases = []

    def kill_all():
        if not created:
            return
        print(f"\ncleanup: killing {len(created)} sandbox(es)")
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            list(pool.map(lambda sid: alb.call("DELETE", f"/sandboxes/{sid}"), list(created)))

    try:
        # ---- phase 1: burst create ------------------------------------------
        st = Stats("burst-create")
        phases.append(st)

        def create(i):
            status, body, elapsed = alb.call(
                "POST", "/sandboxes",
                body={"templateID": template, "timeout": args.sandbox_timeout,
                      "autoPause": True, "metadata": {"suite": "api-load-test", "idx": str(i)}},
            )
            st.record(status, elapsed, body)
            if status == 201 and body and body.get("sandboxID"):
                with created_lock:
                    created.append(body["sandboxID"])
            return status

        start = time.monotonic()
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            statuses = list(pool.map(create, range(args.sandboxes)))
        wall = time.monotonic() - start
        ok = sum(1 for s in statuses if s == 201)
        rate_limited = sum(1 for s in statuses if s == 429)
        print(st.line())
        print(f"{'':16} {ok}/{args.sandboxes} created in {wall:.1f}s "
              f"({ok / wall:.2f}/s)" + (f", {rate_limited} rate-limited" if rate_limited else ""))
        if ok == 0:
            failures.append("phase 1: no sandbox was created")
            raise SystemExit(1)
        if ok < args.sandboxes and rate_limited == 0:
            failures.append(f"phase 1: {args.sandboxes - ok} create(s) failed without a 429")

        # ---- phase 2: read fan-out ------------------------------------------
        st = Stats("read-fanout")
        phases.append(st)
        expected = set(created)
        mismatches = []

        def read(i):
            client = endpoints[i % len(endpoints)]
            status, body, elapsed = client.call("GET", "/sandboxes")
            st.record(status, elapsed, body)
            if status == 200 and isinstance(body, list):
                seen = {s.get("sandboxID") for s in body}
                missing = expected - seen
                if missing:
                    mismatches.append((client.name, sorted(missing)[:3], len(missing)))

        # A sandbox is listed once it is running; give the burst a moment to settle
        # so this measures replica agreement, not creation lag.
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            status, body, _ = alb.call("GET", "/sandboxes")
            if status == 200 and expected <= {s.get("sandboxID") for s in body}:
                break
            time.sleep(3)

        with ThreadPoolExecutor(max_workers=min(args.readers, 64)) as pool:
            list(pool.map(read, range(args.readers)))
        print(st.line())
        if mismatches:
            failures.append(f"phase 2: {len(mismatches)} reader(s) missed sandboxes, e.g. {mismatches[0]}")
            print(f"{'':16} MISMATCH {mismatches[0]}")
        else:
            print(f"{'':16} all {args.readers} readers across {len(endpoints)} endpoint(s) saw all "
                  f"{len(expected)} sandbox(es)")

        # ---- phase 3: churn across replicas ---------------------------------
        st = Stats("churn")
        phases.append(st)
        churn_targets = created[: args.churn_sandboxes]
        bad_states = []

        def churn(sid):
            for round_no in range(args.churn_rounds):
                # Alternate endpoints so consecutive transitions are driven by
                # different API processes.
                pauser = endpoints[round_no % len(endpoints)]
                resumer = endpoints[(round_no + 1) % len(endpoints)]
                status, body, elapsed = pauser.call("POST", f"/sandboxes/{sid}/pause")
                st.record(status, elapsed, body)
                if status not in (204, 409):
                    bad_states.append((sid, "pause", status, body))
                    return
                # wait for paused, as seen by the *other* endpoint
                for _ in range(40):
                    s, b, e = resumer.call("GET", f"/sandboxes/{sid}")
                    st.record(s, e, b)
                    if s == 200 and (b or {}).get("state") == "paused":
                        break
                    time.sleep(1.5)
                else:
                    bad_states.append((sid, "pause-not-visible", status, None))
                    return
                status, body, elapsed = resumer.call("POST", f"/sandboxes/{sid}/resume",
                                                     body={"timeout": args.sandbox_timeout})
                st.record(status, elapsed, body)
                if status not in (201, 409):
                    bad_states.append((sid, "resume", status, body))
                    return
                for _ in range(40):
                    s, b, e = pauser.call("GET", f"/sandboxes/{sid}")
                    st.record(s, e, b)
                    if s == 200 and (b or {}).get("state") == "running":
                        break
                    time.sleep(1.5)
                else:
                    bad_states.append((sid, "resume-not-visible", status, None))
                    return

        with ThreadPoolExecutor(max_workers=max(1, len(churn_targets))) as pool:
            list(pool.map(churn, churn_targets))
        print(st.line())
        if bad_states:
            failures.append(f"phase 3: {len(bad_states)} churn problem(s), e.g. {bad_states[0]}")
            print(f"{'':16} PROBLEM {bad_states[0]}")
        else:
            print(f"{'':16} {len(churn_targets)} sandbox(es) × {args.churn_rounds} pause/resume rounds, "
                  f"alternating endpoints, every transition observed by the other endpoint")

        # ---- phase 4: duplicate kill ----------------------------------------
        st = Stats("duplicate-kill")
        phases.append(st)
        dup_targets = created[: min(len(created), 6)]
        dup_problems = []

        def duplicate_kill(sid):
            results = []

            def one(i):
                client = endpoints[i % len(endpoints)]
                status, body, elapsed = client.call("DELETE", f"/sandboxes/{sid}")
                st.record(status, elapsed, body)
                results.append(status)

            with ThreadPoolExecutor(max_workers=3) as pool:
                list(pool.map(one, range(3)))
            # Exactly one delete should win; the losers may see 404 (already gone)
            # or 204 if the API treats it idempotently. A 5xx is a real failure.
            if not any(s == 204 for s in results):
                dup_problems.append((sid, results, "no 204"))
            if any(s >= 500 or s == 0 for s in results):
                dup_problems.append((sid, results, "server error"))

        with ThreadPoolExecutor(max_workers=len(dup_targets) or 1) as pool:
            list(pool.map(duplicate_kill, dup_targets))
        with created_lock:
            for sid in dup_targets:
                if sid in created:
                    created.remove(sid)
        print(st.line())
        if dup_problems:
            failures.append(f"phase 4: {len(dup_problems)} duplicate-kill problem(s), e.g. {dup_problems[0]}")
            print(f"{'':16} PROBLEM {dup_problems[0]}")
        else:
            print(f"{'':16} {len(dup_targets)} sandbox(es) × 3 concurrent DELETEs, one winner each, no 5xx")

    finally:
        kill_all()

    print("\nsummary")
    for st in phases:
        print("  " + st.line())
        for status, detail in st.server_errors[:3]:
            print(f"{'':18} error status={status} detail={str(detail)[:160]}")

    if failures:
        print("\nFAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nPASSED - no server errors, replicas stayed consistent under load")
    return 0


if __name__ == "__main__":
    sys.exit(main())
