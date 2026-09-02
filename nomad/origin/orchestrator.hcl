job "orchestrator" {
  type = "system"
  datacenters = ["${aws_az1}", "${aws_az2}", "${aws_az3}"]

  priority = 91

  group "client-orchestrator" {
    # Static ports: the API's service discovery resolves orchestrators from
    # these registrations, and the proxy port must be predictable for sandbox
    # traffic.
    network {
      port "orchestrator" {
        static = "5008"
      }

      port "orchestrator-proxy" {
        static = "5007"
      }
    }

    # A crashed orchestrator takes its sandboxes with it, so let Nomad replace
    # the allocation rather than restart in place on a possibly bad host.
    restart {
      attempts = 0
    }

    service {
      name = "orchestrator"
      port = "orchestrator"

      # Nomad-native registration, like upstream. The API reads the address and
      # port straight out of this registration
      # (api/internal/orchestrator/discovery/nomad.go), which is what frees
      # ORCHESTRATOR_PORT in the api job to point the template-builder lookup at
      # the template-manager instead. Registrations with an empty Address are
      # skipped by that discovery, so `port` must stay a port label and never a
      # bare number.
      provider = "nomad"

      # The orchestrator serves an HTTP /health endpoint on its gRPC port; the
      # bare gRPC health protocol is no longer what upstream checks.
      check {
        type     = "http"
        path     = "/health"
        name     = "health"
        interval = "20s"
        timeout  = "5s"
      }
    }

    service {
      name = "orchestrator-proxy"
      port = "orchestrator-proxy"

      provider = "nomad"

      check {
        type     = "tcp"
        name     = "health"
        interval = "30s"
        timeout  = "1s"
      }
    }

    task "start" {
      driver = "raw_exec"

      resources {
        memory     = 1024
        memory_max = -1
      }

      env {
        # The EC2 instance id, not the Nomad UUID, matching upstream's own job.
        # run-nomad.sh names each client after its instance, so the id in an ASG
        # lifecycle event, the Nomad node name and the API's nodeID are one
        # string - which is what lets the scale-in controller talk only to the
        # E2B API instead of also resolving UUIDs through Nomad. A stale UUID
        # left behind by a re-registered client cannot be picked up either.
        NODE_ID     = "${node.unique.name}"
        NODE_IP     = "${attr.unique.network.ip-address}"
        NODE_LABELS = "${meta.node_labels}"

        # Ports are configuration now, not command-line flags.
        GRPC_PORT  = 5008
        PROXY_PORT = 5007

        ENVIRONMENT = "${environment}"
        GIN_MODE    = "release"
        DOMAIN_NAME = "${CFNDOMAIN}"
        PROVIDER    = "aws"

        # Storage. TEMPLATE_BUCKET_PREFIX no longer exists upstream, so the
        # template and build-cache roles each address a dedicated bucket.
        STORAGE_PROVIDER            = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER = "AWS_ECR"
        S3_USE_PATH_STYLE           = "false"
        AWS_REGION                  = "${AWSREGION}"
        TEMPLATE_BUCKET_NAME        = "${BUCKET_TEMPLATES}"
        BUILD_CACHE_BUCKET_NAME     = "${BUCKET_BUILD_CACHE}"
        AWS_DOCKER_REPOSITORY_NAME  = "e2bdev/base"
        SHARED_CHUNK_CACHE_PATH     = ""

        # Replaces commenting 10.0.0.0/8 out of the firewall deny list.
        ALLOW_SANDBOX_INTERNAL_CIDRS = "10.0.0.0/8"

        ENVD_TIMEOUT = "40s"

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
        REDIS_POOL_SIZE     = 10

        LAUNCH_DARKLY_API_KEY = "${launch_darkly_api_key}"

        ORCHESTRATOR_SERVICES = "orchestrator"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", " chmod +x local/orchestrator && local/orchestrator"]
      }

      artifact {
        source      = "s3://${CFNE2BBUCKET}.s3.${AWSREGION}.amazonaws.com/fc-env-pipeline/orchestrator"
        destination = "local/orchestrator"
        mode        = "file"
      }
    }
  }
}
