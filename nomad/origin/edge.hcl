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
        NODE_IP = "$${attr.unique.network.ip-address}"

        EDGE_PORT         = 3001
        EDGE_SECRET       = "${admin_token}"
        PROXY_PORT        = 3002
        ORCHESTRATOR_PORT = 5008

        SERVICE_DISCOVERY_ORCHESTRATOR_PROVIDER             = "DNS"
        SERVICE_DISCOVERY_ORCHESTRATOR_DNS_RESOLVER_ADDRESS = "127.0.0.1:8600" // consul dns resolver
        SERVICE_DISCOVERY_ORCHESTRATOR_DNS_QUERY            = "orchestrator.service.consul,template-manager.service.consul"

        SERVICE_DISCOVERY_EDGE_PROVIDER             = "DNS"
        SERVICE_DISCOVERY_EDGE_DNS_RESOLVER_ADDRESS = "127.0.0.1:8600" // consul dns resolver
        SERVICE_DISCOVERY_EDGE_DNS_QUERY            = "edge-api.service.consul"

        ENVIRONMENT = "dev"

        // use legacy dns resolution for orchestrator services
        USE_PROXY_CATALOG_RESOLUTION = "true"

        OTEL_COLLECTOR_GRPC_ENDPOINT  = "localhost:4317"
        LOGS_COLLECTOR_ADDRESS        = "analytics_collector_host"
        REDIS_URL                     = "${REDIS_ENDPOINT}:6379"
        LOKI_URL                      = "http://loki.service.consul:3100"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-orchestration/client-proxy:latest"
        ports        = ["session", "edge-api"]
      }
    }
  }
}