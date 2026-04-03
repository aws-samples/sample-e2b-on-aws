job "client-proxy" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  node_pool = "api"

  priority = 80

  group "client-proxy" {
  //count = ${count}

  constraint {
    operator  = "distinct_hosts"
    value     = "true"
  }

    network {
      port "session" {
        static = "3002"
      }

      port "edge-api" {
        static = "3001"
      }
    }

    service {
      name = "proxy"
      port = "session"

      check {
        type     = "http"
        name     = "health"
        path     = "/health/traffic"
        interval = "3s"
        timeout  = "3s"
        port     = "edge-api"
      }
    }

    service {
      name = "edge-api"
      port = "3001"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "3s"
        timeout  = "3s"
        port     = "edge-api"
      }
    }

    task "start" {
      driver = "docker"
      # If we need more than 30s we will need to update the max_kill_timeout in nomad
      # https://developer.hashicorp.com/nomad/docs/configuration/client#max_kill_timeout
      kill_signal  = "SIGTERM"

      resources {
        memory_max = 4096
        memory     = 1024
        cpu        = 1000
      }

      env {
        NODE_ID = "$${node.unique.id}"
        HEALTH_PORT = "3001"
        PROXY_PORT  = "3002"

        REDIS_CLUSTER_URL = "${REDIS_ENDPOINT}:6379"
        REDIS_TLS_ENABLED                = "true"
        REDIS_TLS_CA_BASE64          = ""

        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"
        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-orchestration/client-proxy:latest"
        ports        = ["session", "edge-api"]
      }
    }
  }
}