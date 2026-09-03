"""One loop of a client node's drain: mark it draining, then report the facts.

This function makes no decisions. It marks the node if it is not already marked
and returns numbers; the state machine's Choice rules hold every threshold, so
they are visible in the execution history and changeable without a deploy.

Two facts about the API shape this:

  - `GET /nodes/{id}` returns the orchestrator's own live sandbox count, which is
    the same number from either api replica. `sandboxStartingCount` is not on
    that response, and where it does exist it is the answering replica's local
    number - useless as a cluster-wide barrier.
  - A sandbox becomes visible only when Create finishes (MarkRunning at the end
    of Create), and Create does not refuse a draining node. So a zero read is
    only meaningful once the node has been draining long enough for the slowest
    api replica to have stopped placing (cacheSyncTime, 20s) and for any create
    already in flight to have finished or timed out (requestTimeout, 60s). That
    is what quietSeconds measures; the state machine requires 120s of it.

`drainingSince` is carried in the state machine's data rather than read from the
API, because the API's `statusChangedAt` would also move for a status change made
by something else, and because an orchestrator that restarts mid-drain comes back
Healthy - the re-mark has to restart the quiet period, which it does by resetting
this field.
"""

import datetime
import json
import os
import urllib.error
import urllib.request

import boto3

API_BASE = os.environ["API_BASE"].rstrip("/")
ADMIN_TOKEN_SECRET = os.environ["ADMIN_TOKEN_SECRET"]
HTTP_TIMEOUT = 15

secretsmanager = boto3.client("secretsmanager")

# Cached across invocations on a warm container: the secret is stable (it is a
# terraform-managed random_password, not something rotated per apply) and the
# call is billed and rate-limited.
_admin_token = None


def admin_token():
    global _admin_token
    if _admin_token is None:
        _admin_token = secretsmanager.get_secret_value(SecretId=ADMIN_TOKEN_SECRET)["SecretString"]
    return _admin_token


def call(method, path, body=None):
    """Return (status, parsed). Never raises: a transport failure comes back as
    status 0.

    Turning every failure into a value matters for more than tidiness. If this
    raised, the Lambda invocation would fail, the state machine would take its
    Catch branch, and the Choice that owns the give-up thresholds would never
    run - so a node whose API is unreachable would be held by heartbeats until
    the state machine's own timeout instead of the ten minutes the design
    allows."""
    request = urllib.request.Request(
        f"{API_BASE}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={
            "Content-Type": "application/json",
            # X-Admin-Token alone: the admin node routes carry AdminApiKeyAuth
            # without AdminTeamAuth, verified against the running api - no team
            # context needed, so none is configured.
            "X-Admin-Token": admin_token(),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            payload = response.read()
            return response.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        try:
            parsed = json.loads(payload) if payload else None
        except json.JSONDecodeError:
            parsed = payload.decode(errors="replace")
        return exc.code, parsed
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return 0, f"transport error: {exc}"


def handler(event, _context):
    instance_id = event["instanceId"]
    now = datetime.datetime.now(datetime.timezone.utc)

    # How long this execution has been running. The state machine seeds
    # executionStartTime from $$.Execution.StartTime; computing the difference
    # here keeps the Choice rules to plain numeric comparisons instead of needing
    # JSONata or timestamp arithmetic in ASL.
    elapsed_seconds = 0
    started = event.get("executionStartTime")
    if started:
        elapsed_seconds = int(
            (now - datetime.datetime.fromisoformat(started.replace("Z", "+00:00"))).total_seconds()
        )

    # Carried forward from the previous loop; the starter seeds both at 0.
    not_found_streak = event.get("notFoundStreak", 0)
    zero_streak = event.get("zeroStreak", 0)
    draining_since = event.get("drainingSince")

    status_code, node = call("GET", f"/nodes/{instance_id}")

    if status_code == 404:
        # Either the node is genuinely gone, or an api replica restarted and has
        # not resynced. The state machine only treats a streak as "gone".
        result = dict(
            event,
            marked=False,
            notFound=True,
            notFoundStreak=not_found_streak + 1,
            zeroStreak=0,
            sandboxCount=-1,
            quietSeconds=0,
            elapsedSeconds=elapsed_seconds,
            statusCode=status_code,
        )
        print(json.dumps({"instanceId": instance_id, "notFound": True, "streak": result["notFoundStreak"]}))
        return result

    if status_code != 200:
        # Unreachable or refused. Report it as unmarked with no quiet time; the
        # state machine keeps heartbeating and retries on a short loop.
        result = dict(
            event,
            marked=False,
            notFound=False,
            notFoundStreak=0,
            zeroStreak=0,
            sandboxCount=-1,
            quietSeconds=0,
            elapsedSeconds=elapsed_seconds,
            statusCode=status_code,
            error=str(node)[:200],
        )
        print(json.dumps({"instanceId": instance_id, "getStatus": status_code, "body": str(node)[:200]}))
        return result

    status = node.get("status")
    sandbox_count = node.get("sandboxCount", -1)

    if status != "draining":
        # Covers both the first loop and an orchestrator that restarted Healthy.
        post_status, post_body = call("POST", f"/nodes/{instance_id}", {"status": "draining"})
        marked = post_status in (200, 204)
        if marked:
            draining_since = now.isoformat()
            zero_streak = 0
        print(
            json.dumps(
                {
                    "instanceId": instance_id,
                    "action": "mark-draining",
                    "previousStatus": status,
                    "postStatus": post_status,
                    "body": None if marked else str(post_body)[:200],
                }
            )
        )
    else:
        marked = True
        if draining_since is None:
            # The node was already draining when this execution started - someone
            # marked it by hand, or a previous execution did. Start the quiet
            # period now rather than trusting statusChangedAt, which also moves
            # for status changes this controller did not make.
            draining_since = now.isoformat()

    quiet_seconds = 0
    if marked and draining_since:
        quiet_seconds = int((now - datetime.datetime.fromisoformat(draining_since)).total_seconds())

    zero_streak = zero_streak + 1 if (marked and sandbox_count == 0) else 0

    result = dict(
        event,
        marked=marked,
        notFound=False,
        notFoundStreak=0,
        zeroStreak=zero_streak,
        sandboxCount=sandbox_count,
        quietSeconds=quiet_seconds,
        elapsedSeconds=elapsed_seconds,
        drainingSince=draining_since,
        statusCode=status_code,
    )
    print(
        json.dumps(
            {
                "instanceId": instance_id,
                "marked": marked,
                "sandboxCount": sandbox_count,
                "quietSeconds": quiet_seconds,
                "zeroStreak": zero_streak,
            }
        )
    )
    return result
