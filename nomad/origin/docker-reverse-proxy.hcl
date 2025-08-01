job "docker-reverse-proxy" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  node_pool = "default"
  priority = 85

  group "docker-reverse-proxy" {
    network {
      port "docker-reverse-proxy" {
        static = "5000"
      }
    }

    service {
      name = "docker-reverse-proxy"
      port = "docker-reverse-proxy"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "20s"
        timeout  = "5s"
        port     = "docker-reverse-proxy"
      }
    }

    task "start" {
      driver = "docker"

      resources {
        memory_max = 2048
        memory = 512
        cpu    = 256
      }

      env {
        # POSTGRES_CONNECTION_STRING = "${CFNDBURL}"
        # CFNDBURL = "${CFNDBURL}"
        # AWS_REGION                 = "${AWSREGION}"
        # AWS_ACCOUNT_ID             = "${account_id}"
        # AWS_ECR_REPOSITORY         = "e2bdev/base"
        # DOMAIN_NAME                = "${CFNDOMAIN}"
        # LOG_LEVEL                  = "debug"

        CLOUD_PROVIDER             =   "aws"
        POSTGRES_CONNECTION_STRING = "${CFNDBURL}"
        DOMAIN_NAME                = "${CFNDOMAIN}"
        AWS_ECR_REPOSITORY_NAME    = "e2bdev/base"
        LOG_LEVEL                  = "debug"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/docker-reverse-proxy:latest"
        ports        = ["docker-reverse-proxy"]
        args         = ["--port", "5000"]
        force_pull   = true
      }
    }
  }
}