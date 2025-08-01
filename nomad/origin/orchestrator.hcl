job "orchestrator" {
  type = "system"
  datacenters = ["${aws_az1}", "${aws_az2}"]

  priority = 90

  group "client-orchestrator" {
    network {
      port "orchestrator" {
        static = "5008"
      }
    }

    service {
      name = "orchestrator"
      port = "orchestrator"

      check {
        type         = "grpc"
        name         = "health"
        interval     = "20s"
        timeout      = "5s"
        grpc_use_tls = false
        port         = "orchestrator"
      }
    }

    task "start" {
      driver = "raw_exec"

      env {
        NODE_ID                      = "${node.unique.id}"
        CONSUL_TOKEN                 = "${consul_http_token}"
        OTEL_TRACING_PRINT           = false
        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
        LOGS_COLLECTOR_PUBLIC_IP     = "http://127.0.0.1"
        ENVIRONMENT                  = "${environment}"
        TEMPLATE_BUCKET_NAME         = "${BUCKET_FC_TEMPLATE}"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"
        AWS_ENABLED                  = true
        TEMPLATE_AWS_BUCKET_NAME     = "${BUCKET_FC_TEMPLATE}"
        AWS_REGION                   = "${AWSREGION}"
        USE_FIRECRACKER_NATIVE_DIFF  = true
        STORAGE_PROVIDER             = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER  = "AWS_ECR"
        ORCHESTRATOR_SERVICES        = "orchestrator"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", " chmod +x local/orchestrator && local/orchestrator --port 5008 --proxy-port 5007"]
      }

      artifact {
        source = "s3://${CFNSOFTWAREBUCKET}.s3.${AWSREGION}.amazonaws.com/orchestrator"
      }
    }
  }
}
