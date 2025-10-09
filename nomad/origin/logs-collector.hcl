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
        image        = "timberio/vector:0.34.X-alpine"
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

# Enable debugging of logs to the console
# [sinks.console_loki]
# type = "console"
# inputs = ["remove_internal"]
# encoding.codec = "json"

[sinks.local_loki_logs]
type = "loki"
inputs = [ "remove_internal" ]
endpoint = "http://loki.service.consul:3100"
encoding.codec = "json"
# This is recommended behavior for Loki 2.4.0 and newer and is default in Vector 0.39.0 and newer
# https://vector.dev/docs/reference/configuration/sinks/loki/#out_of_order_action
# https://vector.dev/releases/0.39.0/
out_of_order_action = "accept"

[sinks.local_loki_logs.labels]
source = "logs-collector"
service = "{{ service }}"
teamID = "{{ teamID }}"
envID = "{{ envID }}"
buildID = "{{ buildID }}"
sandboxID = "{{ sandboxID }}"
category = "{{ category }}"

        EOH
      }
    }
  }
}