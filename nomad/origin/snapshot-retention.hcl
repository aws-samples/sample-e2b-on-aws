# Deletes sandbox pause snapshots that have not been resumed for 90 days.
#
# Templates and pause snapshots share the templates bucket and the same key
# layout, and every snapshot is a diff whose header points at the builds it was
# layered on (the template, earlier pauses, a fork's checkpoint). An S3 lifecycle
# rule cannot tell them apart and would delete blocks that newer snapshots still
# read, so the decision is made here, from the database and the headers, by
# tools/snapshot-retention. Objects are only deleted for builds that no live
# template or snapshot references. See the tool's package comment for the exact
# rules.
#
# It ships as a dry run (RETENTION_APPLY defaults to false in nomad/prepare.sh)
# and only logs what it would do. Read a run's log first:
#   nomad job periodic force snapshot-retention
#   nomad job status snapshot-retention          # find the child job / alloc
#   nomad alloc logs <alloc-id>
# then set RETENTION_APPLY=true in /opt/config.properties and re-run
# nomad/prepare.sh and `nomad/deploy.sh snapshot-retention`.
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
