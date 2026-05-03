job "docker-reverse-proxy" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  node_pool = "api"
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
      task = "start"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "5s"
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
        DOMAIN_NAME                = "${CFNDOMAIN}"
        AWS_REGION                 = "${AWSREGION}"
        AWS_ECR_REPOSITORY_NAME    = "e2bdev/base"
        LOG_LEVEL                  = "debug"
      }

      template {
        data = <<EOH
POSTGRES_CONNECTION_STRING={{ file "/opt/e2b/secrets/postgres_connection_string" }}
EOH
        destination = "secrets/secrets.env"
        env         = true
        change_mode = "restart"
        perms       = "400"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-orchestration/docker-reverse-proxy:${IMAGE_TAG}"
        ports        = ["docker-reverse-proxy"]
        args         = ["--port", "5000"]
        force_pull   = true
      }
    }
  }
}