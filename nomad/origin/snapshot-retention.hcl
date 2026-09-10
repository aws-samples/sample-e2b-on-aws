# Deletes sandbox pause snapshots that have not been resumed for 90 days, by
# running tools/snapshot-retention once a night. Why this is a job rather than
# an S3 lifecycle rule, how to read a run and how to enable deletion (it ships
# as a dry run) are in the "Snapshot Retention" section of README.md and in the
# tool's package comment.
job "snapshot-retention" {
  type        = "batch"
  datacenters = ["${aws_az1}", "${aws_az2}", "${aws_az3}"]
  node_pool   = "api"
  priority    = 50

  periodic {
    # crons, not the singular cron: Nomad 1.8 deprecates the latter and warns
    # about it on every registration.
    crons            = ["0 3 * * *"]
    time_zone        = "UTC"
    prohibit_overlap = true
  }

  group "retention" {
    count = 1

    # A failed run is not retried: the next daily run picks up where it left
    # off (every step is idempotent), and a retry loop on a persistent error
    # would only repeat the same failure.
    restart {
      attempts = 0
    }

    reschedule {
      attempts  = 0
      unlimited = false
    }

    task "run" {
      driver = "raw_exec"

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 2048
      }

      env {
        # Same database and bucket the api and orchestrator use; the node's
        # instance role already grants s3:* on the templates bucket.
        POSTGRES_CONNECTION_STRING = "${CFNDBURL}"
        TEMPLATE_BUCKET_NAME       = "${BUCKET_TEMPLATES}"
        AWS_REGION                 = "${AWSREGION}"

        # false = dry run. Rendered from /opt/config.properties by prepare.sh.
        RETENTION_APPLY  = "${RETENTION_APPLY}"
        # A snapshot whose newest pause is older than this many days expires.
        RETENTION_DAYS   = "90"
        # Days between soft-deleting an expired snapshot (it disappears from
        # the API) and deleting its objects. Must exceed the longest sandbox
        # lifetime (tiers.max_length_hours); the tool checks and refuses.
        PURGE_DELAY_DAYS = "7"
        # Objects uploaded before upstream stamped build_origin metadata are
        # skipped (SKIP_MISSING_METADATA) unless this is true, in which case the
        # database alone decides that they belong to an expired snapshot.
        RETENTION_ALLOW_MISSING_ORIGIN = "false"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", "chmod +x local/snapshot-retention && local/snapshot-retention"]
      }

      artifact {
        source      = "s3://${CFNE2BBUCKET}.s3.${AWSREGION}.amazonaws.com/fc-env-pipeline/snapshot-retention"
        destination = "local/snapshot-retention"
        mode        = "file"
      }
    }
  }
}
