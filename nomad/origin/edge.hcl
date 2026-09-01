job "client-proxy" {
  datacenters = ["${aws_az1}", "${aws_az2}", "${aws_az3}"]
  node_pool = "api"

  priority = 80

  group "client-proxy" {
    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    # Two restarts in ten minutes, then let Nomad move the allocation to another
    # node with exponential backoff rather than looping on a bad host.
    restart {
      attempts = 2
      interval = "10m"
      delay    = "10s"
      mode     = "fail"
    }

    reschedule {
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "10m"
      unlimited      = true
    }

    # Port names follow upstream: "proxy" carries sandbox traffic, "health"
    # serves the health endpoint. The ALB target group forwards to 3002 and
    # health-checks 3001, so the numbers are unchanged from before.
    network {
      port "proxy" {
        static = "3002"
      }

      port "health" {
        static = "3001"
      }
    }

    # Single registration. The separate "edge-api" service is gone: the edge API
    # now lives in the api job (see its grpc-api / api-internal-grpc services),
    # and client-proxy calls into it instead of exposing its own.
    service {
      name = "client-proxy"
      port = "proxy"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "3s"
        timeout  = "3s"
        port     = "health"
      }
    }

    task "start" {
      driver = "docker"
      # If we need more than 30s we will need to update the max_kill_timeout in nomad
      # https://developer.hashicorp.com/nomad/docs/configuration/client#max_kill_timeout
      kill_signal  = "SIGTERM"

      resources {
        memory_max = 4096
        memory     = 4096
        cpu        = 2000
      }

      env {
        NODE_ID = "${node.unique.id}"
        NODE_IP = "${attr.unique.network.ip-address}"

        HEALTH_PORT = "${NOMAD_PORT_health}"
        PROXY_PORT  = "${NOMAD_PORT_proxy}"

        ENVIRONMENT = "${environment}"

        # Replaces the whole SERVICE_DISCOVERY_* DNS mechanism: the proxy now
        # calls the API's internal gRPC endpoint directly.
        API_INTERNAL_GRPC_ADDRESS = "api-internal-grpc.service.consul:5009"

        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"

        REDIS_CLUSTER_URL   = "${REDIS_ENDPOINT}:6379"
        # ElastiCache Serverless only accepts TLS, and upstream now refuses to start
        # when the CA is set without this flag ("a CA without TLS is meaningless")
        # instead of inferring TLS from the CA being present.
        REDIS_TLS_ENABLED   = "true"
        REDIS_TLS_CA_BASE64 = "${REDIS_CA_B64}"
        REDIS_POOL_SIZE     = 40

        LAUNCH_DARKLY_API_KEY = "${launch_darkly_api_key}"
      }

      config {
        network_mode = "host"
        # force_pull because the tag is :latest and the deploy chain overwrites it
        # in place. Without this, a node that already has a :latest layer keeps
        # running the previous build after a redeploy, so "deployed" would be a
        # claim about ECR rather than about what is running.
        force_pull   = true
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-core/client-proxy:latest"
        ports        = ["proxy", "health"]
      }
    }
  }
}
