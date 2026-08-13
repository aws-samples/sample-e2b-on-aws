job "template-manager" {
  type = "service"
  datacenters = ["${aws_az1}", "${aws_az2}"]
  # Its own pool, like upstream. Sharing a host with the orchestrator does not
  # work: both allocate host-global network slots (veth-<idx>, 10.11.0.x) and
  # both program the nftables rules that redirect sandbox egress to their own
  # proxy port, so the process that writes last takes over the other's
  # sandboxes. A build then dies in provisioning with apt unable to reach
  # deb.debian.org, because its traffic is being handed to the orchestrator's
  # proxy, which does not know the build sandbox.
  #
  # The build pool is provisioned at desired_capacity = 1 in
  # locals.clusters.build (infra-iac/terraform/main.tf).
  node_pool  = "build"
  priority = 75

  group "template-manager" {
    # One allocation per node, the way upstream runs it. Harmless with the
    # single-node default pool, and correct once the pool grows.
    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    # Retry indefinitely with a short delay. Without this stanza Nomad's
    # default for service jobs applies (attempts = 2, mode = fail), which
    # gives up on the allocation after two crashes in 30 minutes.
    restart {
      interval = "5s"
      attempts = 1
      delay    = "5s"
      mode     = "delay"
    }

    network {
      # 5008, the same port the orchestrator uses on the client nodes. The API
      # dials template builders on consts.OrchestratorAPIPort
      # (api/internal/clusters/discovery/local.go hardcodes it), so this and the
      # api job's ORCHESTRATOR_PORT have to agree. Alone on the build pool there
      # is nothing to collide with.
      port "template-manager" {
        static = "5008"
      }
    }

    service {
      name = "template-manager"
      port = "template-manager"

      # Serves an HTTP /health endpoint; the bare gRPC health protocol is no
      # longer what upstream checks.
      check {
        type     = "http"
        path     = "/health"
        name     = "health"
        interval = "20s"
        timeout  = "5s"
      }
    }

    task "start" {
      driver = "raw_exec"

      # Upstream uses 70m only when the nomad autoscaler drives the job; we do
      # not deploy the autoscaler, so this is its non-autoscaler value.
      kill_timeout = "1m"
      kill_signal  = "SIGTERM"

      resources {
        memory     = 1024
        # memory is the scheduling reservation, not a ceiling. Without
        # memory_max the task is hard-capped at that reservation and a template
        # build gets OOM-killed at 1 GiB.
        memory_max = -1
        cpu        = 256
      }

      env {
        NODE_ID     = "${node.unique.name}"
        NODE_LABELS = "${meta.node_labels}"

        # Ports are configuration now, not command-line flags. All the
        # sandbox-network ports from orchestrator/pkg/sandbox/network/pool.go
        # keep their defaults: this job owns its host, so there is nothing to
        # shift away from.
        GRPC_PORT  = 5008
        PROXY_PORT = 5007

        # Skip the sandbox drain phase on shutdown. Upstream sets this on the
        # template-manager whenever the autoscaler is not managing the job,
        # which is our case: this instance holds builds, not live sandboxes,
        # and the 1m kill_timeout above is not enough to drain anyway.
        FORCE_STOP = "true"

        ENVIRONMENT = "${environment}"
        GIN_MODE    = "release"
        DOMAIN_NAME = "${CFNDOMAIN}"

        # Selects the provider-specific branch of the sandbox provisioning
        # script (pkg/template/build/phases/base/provision.sh). It defaults to
        # "gcp", and this job is the one that actually runs the builder, so it
        # has to be set here even though the gcp branch is currently empty.
        PROVIDER = "aws"

        # Storage. TEMPLATE_BUCKET_PREFIX no longer exists upstream, so the
        # template and build-cache roles each address a dedicated bucket.
        STORAGE_PROVIDER            = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER = "AWS_ECR"
        S3_USE_PATH_STYLE           = "false"
        AWS_REGION                  = "${AWSREGION}"
        AWS_DOCKER_REPOSITORY_NAME  = "e2bdev/base"
        TEMPLATE_BUCKET_NAME        = "${BUCKET_TEMPLATES}"
        BUILD_CACHE_BUCKET_NAME     = "${BUCKET_BUILD_CACHE}"

        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"

        # ClickHouse is not deployed; an empty connection string disables it.
        CLICKHOUSE_CONNECTION_STRING = ""

        # Same ElastiCache instance the orchestrator uses. The binary wires
        # Redis for both services and only degrades to a no-op peer registry
        # when the URL is absent, so without these the pool size below was
        # inert and the template cache could not share chunks with peers.
        REDIS_CLUSTER_URL   = "${REDIS_ENDPOINT}:6379"
        REDIS_TLS_CA_BASE64 = "${REDIS_CA_B64}"
        REDIS_POOL_SIZE     = 10

        LAUNCH_DARKLY_API_KEY = "${launch_darkly_api_key}"

        ORCHESTRATOR_SERVICES = "template-manager"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", " chmod +x local/template-manager && local/template-manager"]
      }

      artifact {
        source      = "s3://${CFNE2BBUCKET}.s3.${AWSREGION}.amazonaws.com/fc-env-pipeline/template-manager"
        destination = "local/template-manager"
        mode        = "file"
      }
    }
  }
}
