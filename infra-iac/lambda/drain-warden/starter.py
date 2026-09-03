"""Start one drain execution per client instance waiting to terminate.

Two events reach this function and both are handled the same way, because the
only thing it needs from either is a set of instance ids:

  - the ASG's terminate lifecycle action, delivered by EventBridge, which is the
    fast path;
  - a schedule, which is the reconciler. Lifecycle action events are documented
    best-effort, so an event-only design would occasionally let the hook expire
    and terminate a node with sandboxes still on it - the outcome the whole
    design exists to prevent.

Executions are named after the instance id, so whichever path arrives second
gets ExecutionAlreadyExists and stops there. EventBridge cannot name an
execution when it targets Step Functions directly, which is why this function
exists at all rather than the rule invoking the state machine.
"""

import json
import os

import boto3
from botocore.exceptions import ClientError

ASG_NAME = os.environ["ASG_NAME"]
HOOK_NAME = os.environ["HOOK_NAME"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]

autoscaling = boto3.client("autoscaling")
stepfunctions = boto3.client("stepfunctions")


def waiting_instances():
    """Instance ids of the ASG's members that sit in a terminating wait state."""
    ids = []
    paginator = autoscaling.get_paginator("describe_auto_scaling_groups")
    for page in paginator.paginate(AutoScalingGroupNames=[ASG_NAME]):
        for group in page["AutoScalingGroups"]:
            for instance in group["Instances"]:
                # Terminating:Wait is the hook holding the instance. Terminating:Proceed
                # means the action is already complete and there is nothing to hold.
                if instance["LifecycleState"] == "Terminating:Wait":
                    ids.append(instance["InstanceId"])
    return ids


def start(instance_id):
    """Start the drain execution for one instance. Returns what happened."""
    try:
        stepfunctions.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=instance_id,
            input=json.dumps(
                {
                    "instanceId": instance_id,
                    "asgName": ASG_NAME,
                    "hookName": HOOK_NAME,
                    # Seed the counters the state machine carries between loops so
                    # the first DrainStep does not have to special-case their
                    # absence.
                    "notFoundStreak": 0,
                    "zeroStreak": 0,
                }
            ),
        )
        return "started"
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ExecutionAlreadyExists":
            # The other entry point won the race. Nothing to do, and not a
            # failure: this is the mechanism that makes having both safe.
            return "already-running"
        raise


def handler(event, _context):
    # The lifecycle event carries one instance; the schedule carries none, so the
    # ASG is asked instead. Reconciling from the ASG in both cases would also be
    # correct, but reading the event avoids a describe call on the fast path and,
    # more importantly, works even if the instance has already left
    # Terminating:Wait by the time the schedule next fires.
    detail = event.get("detail") or {}
    if detail.get("EC2InstanceId"):
        instance_ids = [detail["EC2InstanceId"]]
        source = "lifecycle-event"
    else:
        instance_ids = waiting_instances()
        source = "reconciler"

    results = {instance_id: start(instance_id) for instance_id in instance_ids}

    # Only log when there is something to say. The reconciler runs every two
    # minutes forever; logging each empty pass would bury the interesting lines.
    if results:
        print(json.dumps({"source": source, "results": results}))

    return {"source": source, "results": results}
