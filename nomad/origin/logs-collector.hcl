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

[sources.envd]
type = "http_server"
address = "0.0.0.0:30006"
encoding = "json"
path_key = "_path"

[transforms.add_source_envd]
type = "remap"
inputs = ["envd"]
source = """
del(."_path")
.service = "envd"
.sandboxID = .instanceID
if !exists(.envID) {
  .envID = "unknown"
}
if !exists(.category) {
  .category = "default"
}
"""

[transforms.internal_routing]
type = "route"
inputs = [ "add_source_envd" ]

[transforms.internal_routing.route]
internal = '.internal == true'

[transforms.remove_internal]
type = "remap"
inputs = [ "internal_routing._unmatched" ]
source = '''
del(.internal)
'''

[sinks.local_loki_logs]
type = "loki"
inputs = [ "remove_internal" ]
endpoint = "http://loki.service.consul:3100"
encoding.codec = "json"

[sinks.local_loki_logs.labels]
source = "logs-collector"
service = "{{ service }}"
teamID = "{{ teamID }}"
envID = "{{ envID }}"
sandboxID = "{{ sandboxID }}"
category = "{{ category }}"


        EOH
      }
    }
  }
}
