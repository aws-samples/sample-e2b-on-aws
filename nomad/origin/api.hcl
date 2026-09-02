job "api" {
  datacenters = ["${aws_az1}", "${aws_az2}", "${aws_az3}"]
  node_pool = "api"
  priority = 90

  group "api-service" {
    # Two replicas. The API keeps no sandbox state of its own: the only storage
    # backend under api/internal/sandbox/storage is Redis, and every transition
    # runs through an atomic Lua script behind a per-sandbox lock, so a second
    # replica reads the same world rather than a stale copy of it.
    #
    # The ports below are static, so each allocation needs a host of its own -
    # hence the distinct_hosts constraint and two nodes in the api pool
    # (infra-iac/terraform/main.tf). Raising this count without raising the pool
    # leaves the extra allocation unplaced.
    count = 2

    network {
      port "api" {
        static = "50001"
      }

      # Internal gRPC endpoint. client-proxy reaches it through
      # api-internal-grpc.service.consul.
      port "api_internal_grpc" {
        static = "5009"
      }

      # Edge gRPC endpoint, dynamically allocated.
      port "grpc_api" {}
    }

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    restart {
      interval = "5s"
      attempts = 1
      delay    = "5s"
      mode     = "delay"
    }

    service {
      name = "api"
      port = "50001"
      task = "start"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "3s"
        timeout  = "3s"
        port     = "50001"
      }
    }

    service {
      name = "api-internal-grpc"
      port = "api_internal_grpc"
      task = "start"

      check {
        type     = "tcp"
        name     = "api-internal-grpc"
        interval = "3s"
        timeout  = "3s"
        port     = "api_internal_grpc"
      }
    }

    service {
      name = "grpc-api"
      port = "grpc_api"
      task = "start"

      check {
        type     = "tcp"
        name     = "grpc-api"
        interval = "3s"
        timeout  = "3s"
        port     = "grpc_api"
      }
    }

    # Schema migrations run here as a prestart task, so the API never talks to a
    # database older than the binary expects. Replaces applying the flattened
    # infra-iac/db/.migration.sql by hand.
    task "db-migrator" {
      driver = "docker"

      env {
        POSTGRES_CONNECTION_STRING = "${CFNDBURL}"
      }

      config {
        # force_pull because the tag is :latest and the deploy chain overwrites it
        # in place. Without this, a node that already has a :latest layer keeps
        # running the previous build after a redeploy, so "deployed" would be a
        # claim about ECR rather than about what is running.
        force_pull = true
        image      = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-core/db-migrator:latest"
      }

      resources {
        cpu    = 250
        memory = 128
      }

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
    }

    task "start" {
      driver       = "docker"
      # Budget = drain wait + request timeout + cleanup. If this grows past the
      # Nomad client's max_kill_timeout, raise that too.
      # https://developer.hashicorp.com/nomad/docs/configuration/client#max_kill_timeout
      kill_timeout = "150s"
      kill_signal  = "SIGTERM"

      resources {
        memory_max = 8192
        memory     = 8192
        cpu        = 4000
      }

      env {
        NODE_ID            = "${node.unique.id}"
        API_EDGE_GRPC_PORT = "${NOMAD_PORT_grpc_api}"

        # Feeds consts.OrchestratorAPIPort, which
        # api/internal/clusters/discovery/local.go uses as the *template
        # builder's* gRPC port ("we assume ports ... are static"). The
        # template-manager now runs alone on the build pool on 5008, the same
        # port the orchestrator uses on the client nodes, so one value serves
        # both - which is why upstream never had to think about it.
        ORCHESTRATOR_PORT      = 5008
        API_INTERNAL_GRPC_PORT = 5009

        ENVIRONMENT = "${environment}"
        GIN_MODE    = "release"
        DOMAIN_NAME = "${CFNDOMAIN}"

        # Authentication moved from Supabase JWT secrets to a provider config
        # blob. An empty jwt list means "no external JWT issuers".
        AUTH_PROVIDER_CONFIG = "{\"jwt\":[]}"

        POSTGRES_CONNECTION_STRING   = "${CFNDBURL}"
        DB_MAX_OPEN_CONNECTIONS      = 40
        DB_MIN_IDLE_CONNECTIONS      = 5
        AUTH_DB_CONNECTION_STRING    = "${CFNDBURL}"
        AUTH_DB_MAX_OPEN_CONNECTIONS = 20
        AUTH_DB_MIN_IDLE_CONNECTIONS = 5

        NOMAD_TOKEN = "${nomad_acl_token}"

        # orchestrator.hcl now registers Nomad-native services, so the
        # service-based discovery resolves orchestrators on its own. The
        # node-pool fallback must stay off: it derives the address from
        # consts.OrchestratorAPIPort, which now points at the template-manager,
        # so it would hand out template-manager addresses as orchestrators.
        NOMAD_ORCHESTRATOR_LEGACY_DISCOVERY_ENABLED = false

        # Two distinct secrets. They were the same value until it turned out that
        # handing the admin credential to an automation would also hand over the
        # seed that validates every sandbox's traffic access token.
        ADMIN_TOKEN                    = "${admin_token}"
        SANDBOX_ACCESS_TOKEN_HASH_SEED = "${sandbox_access_token_hash_seed}"

        # Persistent-volume access tokens.
        VOLUME_TOKEN_ISSUER           = "${CFNDOMAIN}"
        VOLUME_TOKEN_SIGNING_KEY      = "HMAC:${VOLUME_TOKEN_KEY_B64}"
        VOLUME_TOKEN_SIGNING_KEY_NAME = "e2b-volume-token-key"
        VOLUME_TOKEN_DURATION         = "1h"
        VOLUME_TOKEN_SIGNING_METHOD   = "HS256"

        LOKI_URL                     = "http://loki.service.consul:3100"
        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"

        # ClickHouse is not deployed; an empty connection string disables it.
        CLICKHOUSE_CONNECTION_STRING = ""

        REDIS_CLUSTER_URL   = "${REDIS_ENDPOINT}:6379"
        # ElastiCache Serverless only accepts TLS, and upstream now refuses to start
        # when the CA is set without this flag ("a CA without TLS is meaningless")
        # instead of inferring TLS from the CA being present.
        REDIS_TLS_ENABLED   = "true"
        REDIS_TLS_CA_BASE64 = "${REDIS_CA_B64}"
        REDIS_POOL_SIZE     = 160

        LAUNCH_DARKLY_API_KEY = "${launch_darkly_api_key}"

        POSTHOG_API_KEY               = ""
        ANALYTICS_COLLECTOR_HOST      = ""
        ANALYTICS_COLLECTOR_API_TOKEN = ""

        AWS_REGION                 = "${AWSREGION}"
        AWS_DOCKER_REPOSITORY_NAME = "e2bdev/base"

        # Required by transitively imported code that never reads it on this
        # path; the orchestrator and template-manager own real template storage.
        TEMPLATE_BUCKET_NAME = "skip"
      }

      config {
        network_mode = "host"
        # force_pull because the tag is :latest and the deploy chain overwrites it
        # in place. Without this, a node that already has a :latest layer keeps
        # running the previous build after a redeploy, so "deployed" would be a
        # claim about ECR rather than about what is running.
        force_pull   = true
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-core/api:latest"
        ports        = ["api", "grpc_api"]
        args         = [
          "--port", "50001",
        ]
        volumes = []
      }
    }
  }
}
