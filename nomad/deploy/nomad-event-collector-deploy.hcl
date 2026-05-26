job "nomad-event-collector" {
  datacenters = ["us-west-2a", "us-west-2b"]
  type        = "service"
  node_pool   = "default"

  priority = 90

  group "nomad-event-collector" {
    count = 1

    restart {
      attempts = 10
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    task "start" {
      driver = "raw_exec"

      resources {
        memory = 128
        cpu    = 100
      }

      env {
        NOMAD_ADDR          = "https://${attr.unique.network.ip-address}:4646"
        OTLP_LOGS_ENDPOINT  = "http://127.0.0.1:4318/v1/logs"
        OTEL_CLUSTER        = ""
        RAW_PAYLOAD_ENABLED = "false"
      }

      template {
        destination = "local/config/nomad-ca.pem"
        data        = "{{ file \"/opt/nomad/tls/ca.pem\" }}"
        change_mode = "restart"
        perms       = "400"
      }

      template {
        destination = "local/config/nomad-cert.pem"
        data        = "{{ file \"/opt/nomad/tls/cert.pem\" }}"
        change_mode = "restart"
        perms       = "400"
      }

      template {
        destination = "local/config/nomad-key.pem"
        data        = "{{ file \"/opt/nomad/tls/key.pem\" }}"
        change_mode = "restart"
        perms       = "400"
      }

      template {
        destination = "secrets/nomad-event.env"
        env         = true
        change_mode = "restart"
        perms       = "400"
        data        = <<EOH
NOMAD_TOKEN={{ file "/opt/e2b/secrets/nomad_acl_token" }}
EOH
      }

      template {
        destination = "local/nomad-event-collector.py"
        change_mode = "restart"
        perms       = "755"
        data        = <<PY
#!/usr/bin/env python3
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


TOPICS = ("Deployment", "Evaluation", "Allocation", "Node", "Job")
SEVERITY_INFO = 9


def env(name, default=""):
    return os.environ.get(name, default)


nomad_addr = env("NOMAD_ADDR", "https://127.0.0.1:4646").rstrip("/")
nomad_token = env("NOMAD_TOKEN")
otlp_logs_endpoint = env("OTLP_LOGS_ENDPOINT", "http://127.0.0.1:4318/v1/logs")
cluster = env("OTEL_CLUSTER", "unknown")
# raw_payload_enabled = false; only enable briefly during incident debugging.
raw_payload_enabled = env("RAW_PAYLOAD_ENABLED", "false").lower() == "true"


def ssl_context():
    ctx = ssl.create_default_context(cafile="local/config/nomad-ca.pem")
    ctx.load_cert_chain("local/config/nomad-cert.pem", "local/config/nomad-key.pem")
    ctx.check_hostname = False
    return ctx


def string_attr(key, value):
    return {"key": key, "value": {"stringValue": "" if value is None else str(value)}}


def int_attr(key, value):
    if value is None:
        return string_attr(key, "")
    return {"key": key, "value": {"intValue": str(value)}}


def json_attr(key, value):
    if value is None:
        return string_attr(key, "")
    return string_attr(key, json.dumps(value, separators=(",", ":"), sort_keys=True))


def first_payload(payload):
    if not isinstance(payload, dict):
        return {}
    for key in ("Allocation", "Evaluation", "Deployment", "Job", "Node"):
        item = payload.get(key)
        if isinstance(item, dict):
            return item
    return {}


def task_group_deployment_summary(item):
    groups = item.get("TaskGroups")
    if not isinstance(groups, dict):
        return {}
    totals = {
        "desired_total": 0,
        "placed_allocs": 0,
        "healthy_allocs": 0,
        "unhealthy_allocs": 0,
    }
    for group in groups.values():
        if not isinstance(group, dict):
            continue
        totals["desired_total"] += int(group.get("DesiredTotal") or 0)
        totals["placed_allocs"] += int(group.get("PlacedAllocs") or 0)
        totals["healthy_allocs"] += int(group.get("HealthyAllocs") or 0)
        totals["unhealthy_allocs"] += int(group.get("UnhealthyAllocs") or 0)
    return totals


def event_time_unix_nano(item):
    for key in ("ModifyTime", "CreateTime"):
        value = item.get(key)
        if isinstance(value, int) and value > 0:
            return str(value)
    return str(time.time_ns())


def normalize_event(event):
    item = first_payload(event.get("Payload"))
    deploy = task_group_deployment_summary(item)
    attributes = [
        string_attr("nomad.topic", event.get("Topic")),
        string_attr("nomad.type", event.get("Type")),
        int_attr("nomad.index", event.get("Index")),
        string_attr("nomad.namespace", event.get("Namespace")),
        string_attr("nomad.key", event.get("Key")),
        json_attr("nomad.filter_keys", event.get("FilterKeys")),
        string_attr("nomad.job_id", item.get("JobID") or item.get("ID") if event.get("Topic") == "Job" else item.get("JobID")),
        string_attr("nomad.task_group", item.get("TaskGroup")),
        string_attr("nomad.alloc_id", item.get("ID") if event.get("Topic") == "Allocation" else item.get("AllocID")),
        string_attr("nomad.eval_id", item.get("EvalID") or (item.get("ID") if event.get("Topic") == "Evaluation" else "")),
        string_attr("nomad.deployment_id", item.get("DeploymentID") or (item.get("ID") if event.get("Topic") == "Deployment" else "")),
        string_attr("nomad.node_id", item.get("NodeID") or item.get("ID") if event.get("Topic") == "Node" else item.get("NodeID")),
        string_attr("nomad.node_name", item.get("NodeName") or item.get("Name")),
        string_attr("nomad.status", item.get("Status")),
        string_attr("nomad.status_description", item.get("StatusDescription")),
        string_attr("nomad.client_status", item.get("ClientStatus")),
        string_attr("nomad.desired_status", item.get("DesiredStatus")),
        string_attr("nomad.triggered_by", item.get("TriggeredBy")),
        json_attr("nomad.queued_allocations", item.get("QueuedAllocations")),
        int_attr("nomad.desired_total", deploy.get("desired_total")),
        int_attr("nomad.placed_allocs", deploy.get("placed_allocs")),
        int_attr("nomad.healthy_allocs", deploy.get("healthy_allocs")),
        int_attr("nomad.unhealthy_allocs", deploy.get("unhealthy_allocs")),
    ]
    if raw_payload_enabled:
        attributes.append(json_attr("nomad.raw_payload", event.get("Payload")))
    body = {
        "topic": event.get("Topic"),
        "type": event.get("Type"),
        "job_id": item.get("JobID"),
        "status": item.get("Status"),
        "client_status": item.get("ClientStatus"),
        "desired_status": item.get("DesiredStatus"),
        "triggered_by": item.get("TriggeredBy"),
        "queued_allocations": item.get("QueuedAllocations"),
        **deploy,
    }
    return {
        "timeUnixNano": event_time_unix_nano(item),
        "severityNumber": SEVERITY_INFO,
        "severityText": "INFO",
        "body": {"stringValue": json.dumps(body, separators=(",", ":"), sort_keys=True)},
        "attributes": attributes,
    }


def post_logs(records):
    if not records:
        return
    payload = {
        "resourceLogs": [{
            "resource": {
                "attributes": [
                    string_attr("service.name", "nomad-event-collector"),
                    string_attr("cluster", cluster),
                ],
            },
            "scopeLogs": [{
                "scope": {"name": "nomad-event-stream"},
                "logRecords": records,
            }],
        }],
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        otlp_logs_endpoint,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


def stream_url(index):
    params = [("topic", topic) for topic in TOPICS]
    if index:
        params.append(("index", str(index)))
    return nomad_addr + "/v1/event/stream?" + urllib.parse.urlencode(params)


def current_nomad_index():
    req = urllib.request.Request(nomad_addr + "/v1/jobs", headers={"X-Nomad-Token": nomad_token})
    with urllib.request.urlopen(req, context=ssl_context(), timeout=10) as resp:
        resp.read()
        value = resp.headers.get("X-Nomad-Index")
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def stream_once(index):
    req = urllib.request.Request(stream_url(index), headers={"X-Nomad-Token": nomad_token})
    with urllib.request.urlopen(req, context=ssl_context(), timeout=300) as resp:
        for raw in resp:
            if not raw:
                continue
            line = raw.decode("utf-8", "replace").strip()
            if not line or line == "{}":
                continue
            envelope = json.loads(line)
            next_index = envelope.get("Index") or index
            events = envelope.get("Events") or []
            post_logs([normalize_event(event) for event in events])
            index = next_index
    return index


def main():
    if not nomad_token:
        raise SystemExit("NOMAD_TOKEN is required")
    index = current_nomad_index()
    while True:
        try:
            index = stream_once(index)
        except (urllib.error.URLError, TimeoutError, socket.timeout, ssl.SSLError, json.JSONDecodeError) as exc:
            print(f"nomad event stream error: {exc}", file=sys.stderr, flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
PY
      }

      config {
        command = "/usr/bin/python3"
        args    = ["local/nomad-event-collector.py"]
      }
    }
  }
}
