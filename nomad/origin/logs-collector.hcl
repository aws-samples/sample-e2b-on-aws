job "logs-collector" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  type        = "system"
  node_pool    = "all"

  priority = 85

  group "logs-collector" {
    network {
      port "health" {
        to = 44313
      }
      port "logs" {
        to = 30006
      }
    }

    service {
      name = "logs-collector"
      port = "logs"
      tags = [
        "logs",
        "health",
      ]

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "20s"
        timeout  = "5s"
        port     = 44313
      }
    }

    task "start-collector" {
      driver = "docker"

      config {
        network_mode = "host"
        dns_servers  = ["127.0.0.53"]
        image        = "timberio/vector:0.44.0-alpine"
        auth_soft_fail = true
        ports = [
          "health",
          "logs",
        ]
      }

      env {
        VECTOR_CONFIG          = "local/vector.toml"
        VECTOR_REQUIRE_HEALTHY = "true"
        VECTOR_LOG             = "warn"
      }

      resources {
        memory_max = 4096
        memory     = 512
        cpu        = 500
      }

      template {
        destination   = "local/vector.toml"
        change_mode   = "signal"
        change_signal = "SIGHUP"
        # overriding the delimiters to [[ ]] to avoid conflicts with Vector's native templating, which also uses {{ }}
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = <<EOH
data_dir = "alloc/data/vector/"

[api]
enabled = true
address = "0.0.0.0:44313"

[sources.http_server]
type = "http_server"
address = "0.0.0.0:30006"
encoding = "ndjson"
path_key = "_path"

[transforms.add_source_http_server]
type = "remap"
inputs = ["http_server"]
source = """
del(."_path")
.sandboxID = .instanceID
.timestamp = parse_timestamp(.timestamp, format: "%+") ?? now()
# Normalize keys
if exists(.sandbox_id) {
  .sandboxID = .sandbox_id
}
if exists(.build_id) {
  .buildID = .build_id
}
if exists(.env_id) {
  .envID = .env_id
}
if exists(.team_id) {
  .teamID = .team_id
}
if exists(."template.id") {
  .templateID = ."template.id"
  del(."template.id")
}
if exists(."sandbox.id") {
  .sandboxID = ."sandbox.id"
  del(."sandbox.id")
}
if exists(."build.id") {
  .buildID = ."build.id"
  del(."build.id")
}
if exists(."env.id") {
  .envID = ."env.id"
  del(."env.id")
}
if exists(."team.id") {
  .teamID = ."team.id"
  del(."team.id")
}

# Apply defaults if not already set
if !exists(.envID) {
  .envID = "unknown"
}
if !exists(.category) {
  .category = "default"
}
if !exists(.teamID) {
  .teamID = "unknown"
}
if !exists(.sandboxID) {
  .sandboxID = "unknown"
}
if !exists(.buildID) {
  .buildID = "unknown"
}
if !exists(.service) {
  .service = "envd"
}
"""

[transforms.internal_routing]
type = "route"
inputs = [ "add_source_http_server" ]

[transforms.internal_routing.route]
internal = '.internal == true'

[transforms.remove_internal]
type = "remap"
inputs = [ "internal_routing._unmatched" ]
source = '''
del(.internal)
'''

[transforms.to_otel_logs]
type = "remap"
inputs = [ "remove_internal" ]
source = '''
severity_text = if .level == "debug" {
  "DEBUG"
} else if .level == "info" {
  "INFO"
} else if .level == "warn" {
  "WARN"
} else if .level == "error" {
  "ERROR"
} else if .level == "dpanic" {
  "ERROR"
} else if .level == "panic" {
  "FATAL"
} else if .level == "fatal" {
  "FATAL"
} else {
  upcase(to_string(.level) ?? "INFO")
}

logger_name = to_string(.logger) ?? "sandbox"
trace_id = if exists(.traceID) { to_string(.traceID) ?? "" } else { "" }
template_id = if exists(.templateID) { to_string(.templateID) ?? "" } else { "" }
stacktrace = if exists(.stacktrace) { to_string(.stacktrace) ?? "" } else { "" }
event_type = if exists(.event_type) { to_string(.event_type) ?? "" } else { "" }
operation_id = if exists(.operation_id) { to_string(.operation_id) ?? "" } else { "" }
data = if exists(.data) { to_string(.data) ?? "" } else { "" }
message = if data != "" && (event_type == "stdout" || event_type == "stderr") {
  data
} else {
  to_string(.message) ?? ""
}

. = {
  "resourceLogs": [{
    "resource": {
      "attributes": [
        { "key": "service.name", "value": { "stringValue": to_string(.service) ?? "envd" } },
        { "key": "e2b.team_id", "value": { "stringValue": to_string(.teamID) ?? "unknown" } },
        { "key": "e2b.env_id", "value": { "stringValue": to_string(.envID) ?? "unknown" } },
        { "key": "e2b.build_id", "value": { "stringValue": to_string(.buildID) ?? "unknown" } },
        { "key": "e2b.sandbox_id", "value": { "stringValue": to_string(.sandboxID) ?? "unknown" } },
        { "key": "e2b.category", "value": { "stringValue": to_string(.category) ?? "default" } }
      ]
    },
    "scopeLogs": [{
      "scope": {
        "name": logger_name
      },
      "logRecords": [{
        "timeUnixNano": to_unix_timestamp!(.timestamp, unit: "nanoseconds"),
        "body": { "stringValue": message },
        "severityText": severity_text,
        "attributes": [
          { "key": "logger", "value": { "stringValue": logger_name } },
          { "key": "level", "value": { "stringValue": to_string(.level) ?? "" } },
          { "key": "event_type", "value": { "stringValue": event_type } },
          { "key": "operation_id", "value": { "stringValue": operation_id } },
          { "key": "traceID", "value": { "stringValue": trace_id } },
          { "key": "templateID", "value": { "stringValue": template_id } },
          { "key": "stacktrace", "value": { "stringValue": stacktrace } }
        ]
      }]
    }]
  }]
}
'''

# Enable debugging of logs to the console
# [sinks.console_loki]
# type = "console"
# inputs = ["remove_internal"]
# encoding.codec = "json"

[sinks.local_otel_logs]
type = "opentelemetry"
inputs = [ "to_otel_logs" ]
healthcheck.enabled = true

[sinks.local_otel_logs.protocol]
type = "http"
uri = "http://127.0.0.1:4319/v1/logs"
method = "post"

[sinks.local_otel_logs.protocol.encoding]
codec = "json"

[sinks.local_otel_logs.protocol.framing]
method = "newline_delimited"

[sinks.local_otel_logs.protocol.request.headers]
content-type = "application/json"

        EOH
      }
    }
  }
}
