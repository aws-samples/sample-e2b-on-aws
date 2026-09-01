#!/bin/bash
# Tear down everything the deploy chain created from step 2 (packer) onward, in
# reverse order of creation:
#
#   step 8  create_template.sh   per-template ECR repos, template + build-cache objects
#   step 7  nomad/deploy.sh      running jobs and their sandboxes
#   step 6  nomad/prepare.sh     rendered deploy/*.hcl
#   step 5  build-and-upload.sh  e2b-core/* ECR repos, fc-* objects in the E2B bucket
#   step 3  terraform/start.sh   ASGs, ALB, security groups, secrets, IAM, launch templates
#   step 2  packer.sh            the orchestrator AMI and its snapshots
#
# Deliberately left alone: step 1's /opt/config.properties CFN outputs, and
# everything CloudFormation owns (VPC, Aurora, ElastiCache, the four buckets,
# this bastion). Deleting the stack does NOT cascade into any of the above -
# Terraform's resources are not stack members - which is why this script exists.
#
# The stack itself is destroy-cnf.sh's job, and it has to run second: the
# Terraform state lives in s3://<e2b bucket>/terraform-state/, so emptying the
# buckets before the destroy below would orphan every Terraform resource.
#
# Usage:
#   destroy.sh                  interactive, everything from step 2 onward
#   destroy.sh --yes            no confirmation prompt
#   destroy.sh --dry-run        print what would be deleted, touch nothing
#   destroy.sh --keep-artifacts leave ECR repos and S3 objects in place
#
# Exits non-zero if any step failed, so a wrapper can tell a partial teardown
# from a clean one.

set -uo pipefail

DRY_RUN=false
ASSUME_YES=false
KEEP_ARTIFACTS=false
FAILURES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=true ;;
        --yes|-y)         ASSUME_YES=true ;;
        --keep-artifacts) KEEP_ARTIFACTS=true ;;
        -h|--help)        sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# Simple commands only - anything with a pipe or redirect has to be guarded by
# an `if $DRY_RUN` block instead.
run() {
    if $DRY_RUN; then
        printf '    [dry-run] %s\n' "$*"

        return 0
    fi
    if ! "$@"; then
        FAILURES=$((FAILURES + 1))
        printf '    ! failed: %s\n' "$*" >&2

        return 1
    fi
}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_FILE="/opt/config.properties"

for tool in aws jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required but not installed." >&2; exit 1; }
done

[ -f "$CONFIG_FILE" ] || { echo "$CONFIG_FILE does not exist; nothing to tear down from." >&2; exit 1; }

cfg() { grep -E "^$1=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-; }

REGION=$(cfg AWSREGION)
STACK_NAME=$(cfg CFNSTACKNAME)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
BUCKET_E2B=$(cfg BUCKET_E2B);                 [ -n "$BUCKET_E2B" ]        || BUCKET_E2B=$(cfg CFNE2BBUCKET)
BUCKET_TEMPLATES=$(cfg BUCKET_TEMPLATES);     [ -n "$BUCKET_TEMPLATES" ]  || BUCKET_TEMPLATES=$(cfg CFNTEMPLATESBUCKET)
BUCKET_BUILD_CACHE=$(cfg BUCKET_BUILD_CACHE); [ -n "$BUCKET_BUILD_CACHE" ]|| BUCKET_BUILD_CACHE=$(cfg CFNBUILDCACHEBUCKET)
BUCKET_LOKI=$(cfg CFNLOKIBUCKET)

[ -n "$REGION" ]     || { echo "AWSREGION missing from $CONFIG_FILE." >&2; exit 1; }
[ -n "$STACK_NAME" ] || { echo "CFNSTACKNAME missing from $CONFIG_FILE." >&2; exit 1; }
[ -n "$ACCOUNT_ID" ] || { echo "Could not resolve the AWS account ID." >&2; exit 1; }

cat <<EOF

Region        : $REGION
Stack         : $STACK_NAME
Account       : $ACCOUNT_ID
E2B bucket    : ${BUCKET_E2B:-<unknown>}
Templates     : ${BUCKET_TEMPLATES:-<unknown>}
Build cache   : ${BUCKET_BUILD_CACHE:-<unknown>}
Artifacts     : $($KEEP_ARTIFACTS && echo "kept" || echo "deleted")
CFN stack     : untouched (see destroy-cnf.sh)
Mode          : $($DRY_RUN && echo "dry-run" || echo "LIVE")
EOF

if ! $DRY_RUN && ! $ASSUME_YES; then
    printf '\nThis destroys the cluster and cannot be undone. Type the stack name to continue: '
    read -r reply
    [ "$reply" = "$STACK_NAME" ] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# step 7 - stop the Nomad jobs first so sandboxes are torn down by the
# orchestrator rather than dying with the instance.
# ---------------------------------------------------------------------------
log "step 7: stopping Nomad jobs"
if [ -f /tmp/nomad_env.sh ]; then
    # shellcheck disable=SC1091
    . /tmp/nomad_env.sh
fi
if command -v nomad >/dev/null 2>&1 && [ -n "${NOMAD_ADDR:-}" ] && nomad status >/dev/null 2>&1; then
    for job in template-manager client-proxy orchestrator api loki logs-collector otel-collector; do
        if nomad job status "$job" >/dev/null 2>&1; then
            run nomad job stop -purge -yes "$job"
        fi
    done
else
    note "Nomad is unreachable; skipping. The jobs disappear with their nodes anyway."
fi

# ---------------------------------------------------------------------------
# step 8 - per-template ECR repositories.
#
# The template IDs come from this deployment's own database. They are never
# guessed from a wildcard: the account also holds e2bdev/base/<id> repositories
# belonging to other E2B deployments, and deleting those would be someone
# else's outage.
# ---------------------------------------------------------------------------
if ! $KEEP_ARTIFACTS; then
    log "step 8: template artifacts"
    TEMPLATE_IDS=""
    DB_SECRET=$(cfg CFNDBCredentialSecretName)
    if [ -n "$DB_SECRET" ] && command -v psql >/dev/null 2>&1; then
        DB_JSON=$(aws secretsmanager get-secret-value --region "$REGION" \
            --secret-id "$DB_SECRET" --query SecretString --output text 2>/dev/null)
        if [ -n "$DB_JSON" ]; then
            TEMPLATE_IDS=$(PGPASSWORD=$(echo "$DB_JSON" | jq -r .password) \
                psql -h "$(echo "$DB_JSON" | jq -r .host)" \
                     -p "$(echo "$DB_JSON" | jq -r .port)" \
                     -U "$(echo "$DB_JSON" | jq -r .username)" \
                     -d "$(echo "$DB_JSON" | jq -r .dbname)" \
                     -tAc 'SELECT id FROM envs' 2>/dev/null)
        fi
    fi

    if [ -n "$TEMPLATE_IDS" ]; then
        for tid in $TEMPLATE_IDS; do
            repo="e2bdev/base/$tid"
            if aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1; then
                run aws ecr delete-repository --region "$REGION" --repository-name "$repo" --force
            fi
        done
        note "Processed $(echo "$TEMPLATE_IDS" | wc -w) template ID(s) from the database."
    else
        note "Could not read template IDs from the database."
        note "Per-template repositories are left in place - delete them by hand:"
        note "  aws ecr delete-repository --region $REGION --repository-name e2bdev/base/<templateID> --force"
        note "Do NOT wildcard e2bdev/base/* - other deployments share that namespace."
    fi

    # The shared base repository is written by tools/legacy/create_template.sh and
    # read by shared/pkg/artifacts-registry/registry_aws.go.
    if aws ecr describe-repositories --region "$REGION" --repository-names "e2bdev/base" >/dev/null 2>&1; then
        run aws ecr delete-repository --region "$REGION" --repository-name "e2bdev/base" --force
    fi

    for bucket in "$BUCKET_TEMPLATES" "$BUCKET_BUILD_CACHE"; do
        if [ -n "$bucket" ] && aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
            run aws s3 rm "s3://$bucket" --recursive --region "$REGION" --only-show-errors
        fi
    done
fi

# ---------------------------------------------------------------------------
# step 5 - images and binaries published by tools/build-and-upload.sh.
#
# terraform-state/ and cluster-setup/ are deliberately untouched here: the state
# is what the terraform destroy below needs, and the cluster-setup objects are
# terraform-managed and go away with it.
# ---------------------------------------------------------------------------
if ! $KEEP_ARTIFACTS; then
    log "step 5: build artifacts"
    for repo in e2b-core/api e2b-core/db-migrator e2b-core/client-proxy; do
        if aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1; then
            run aws ecr delete-repository --region "$REGION" --repository-name "$repo" --force
        fi
    done

    if [ -n "$BUCKET_E2B" ] && aws s3api head-bucket --bucket "$BUCKET_E2B" --region "$REGION" >/dev/null 2>&1; then
        for prefix in fc-env-pipeline fc-kernels fc-versions fc-busybox; do
            run aws s3 rm "s3://$BUCKET_E2B/$prefix/" --recursive --region "$REGION" --only-show-errors
        done
    fi
fi

# ---------------------------------------------------------------------------
# step 3 - terraform. The ALB carries deletion protection when it is enabled,
# which makes the destroy fail late, so clear it first.
# ---------------------------------------------------------------------------
log "step 3: terraform destroy"
ALB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?Type=='application' && contains(LoadBalancerName, '$STACK_NAME')].LoadBalancerArn" \
    --output text 2>/dev/null)
for arn in $ALB_ARNS; do
    protected=$(aws elbv2 describe-load-balancer-attributes --region "$REGION" --load-balancer-arn "$arn" \
        --query "Attributes[?Key=='deletion_protection.enabled'].Value" --output text 2>/dev/null)
    if [ "$protected" = "true" ]; then
        run aws elbv2 modify-load-balancer-attributes --region "$REGION" --load-balancer-arn "$arn" \
            --attributes Key=deletion_protection.enabled,Value=false --output json
    fi
done

TERRAFORM_DIR="$REPO_ROOT/infra-iac/terraform"
if [ ! -d "$TERRAFORM_DIR" ] || ! command -v terraform >/dev/null 2>&1; then
    note "terraform or $TERRAFORM_DIR is missing; skipping. Its 50+ resources will survive."
    FAILURES=$((FAILURES + 1))
elif [ ! -f "$TERRAFORM_DIR/var.tf" ]; then
    note "var.tf is absent - run terraform/prepare.sh first, or the destroy has no variables."
    FAILURES=$((FAILURES + 1))
else
    # -refresh=false on purpose. A destroy plan still evaluates data sources, and
    # data.aws_ami.e2b resolves ${STACK_NAME}-orch-*; if that AMI is missing the
    # plan fails with "Your query returned no results" and the state is stuck
    # with no way to destroy what it tracks. Refreshing buys nothing here - drift
    # does not matter when the target state is "gone".
    ENVIRONMENT=$(cfg CFNENVIRONMENT)
    if $DRY_RUN; then
        note "[dry-run] terraform destroy -auto-approve -refresh=false -var=environment=${ENVIRONMENT:-dev}"
    elif ! (cd "$TERRAFORM_DIR" && terraform destroy -auto-approve -refresh=false -var="environment=${ENVIRONMENT:-dev}"); then
        FAILURES=$((FAILURES + 1))
        note "! terraform destroy failed - re-run before deleting the stack, or the"
        note "  state in s3://$BUCKET_E2B/terraform-state/ becomes unreachable orphaned state."
    fi
fi

# ---------------------------------------------------------------------------
# Secrets Manager keeps a 30-day recovery window by default (main.tf does not
# set recovery_window_in_days), so the names stay taken and a redeploy fails
# with "already scheduled for deletion". Force them out.
# ---------------------------------------------------------------------------
log "purging Secrets Manager entries scheduled for deletion"
# The candidate names are built from main.tf's aws_secretsmanager_secret
# resources rather than discovered. list-secrets is only an enrichment: the
# bastion instance role can describe and read a secret but is not granted
# secretsmanager:ListSecrets, so a discovery-only version of this step silently
# found nothing and left all six names occupied.
SECRET_SUFFIXES="api-secret consul-secret-id consul-dns-request-token consul-gossip-key launch-darkly-api-key nomad-secret-id"
CANDIDATES=""
for suffix in $SECRET_SUFFIXES; do
    CANDIDATES="$CANDIDATES ${STACK_NAME}-${suffix}"
done
LISTED=$(aws secretsmanager list-secrets --region "$REGION" --include-planned-deletion \
    --query "SecretList[?starts_with(Name, '${STACK_NAME}-')].Name" --output text 2>/dev/null)
CANDIDATES=$(printf '%s %s' "$CANDIDATES" "$LISTED" | tr ' \t' '\n\n' | grep -v '^$' | sort -u)

PURGED=0
for secret in $CANDIDATES; do
    # A scheduled-for-deletion secret still answers describe-secret and still
    # owns its name, which is what breaks the next deploy.
    if aws secretsmanager describe-secret --region "$REGION" --secret-id "$secret" >/dev/null 2>&1; then
        if run aws secretsmanager delete-secret --region "$REGION" --secret-id "$secret" \
                --force-delete-without-recovery --output json; then
            PURGED=$((PURGED + 1))
        fi
    fi
done
note "Purged $PURGED secret(s). The CFN-owned DB credential does not match ${STACK_NAME}- and is left alone."

# ---------------------------------------------------------------------------
# step 2 - the packer AMI and the snapshots behind it. Neither is managed by
# terraform or CloudFormation, so nothing else will ever clean them up.
# ---------------------------------------------------------------------------
log "step 2: orchestrator AMI (kept)"
AMI_IDS=$(aws ec2 describe-images --region "$REGION" --owners self \
    --filters "Name=name,Values=${STACK_NAME}-orch-*" --query 'Images[].ImageId' --output text 2>/dev/null)
if [ -n "$AMI_IDS" ]; then
    note "Keeping: $AMI_IDS"
    note "The AMI survives teardown on purpose. Two reasons:"
    note "  - main.tf's data.aws_ami.e2b looks it up by ${STACK_NAME}-orch-*, and a"
    note "    destroy plan cannot even be built once that lookup returns nothing"
    note "    (\"Your query returned no results\"), which strands the state."
    note "  - a redeploy can then skip packer.sh, which takes ~13 minutes."
    note "To reclaim the storage, deregister it and delete its snapshots by hand:"
    for ami in $AMI_IDS; do
        SNAPSHOTS=$(aws ec2 describe-images --region "$REGION" --image-ids "$ami" \
            --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' --output text 2>/dev/null)
        note "  aws ec2 deregister-image --region $REGION --image-id $ami"
        for snap in $SNAPSHOTS; do
            [ "$snap" = "None" ] && continue
            note "  aws ec2 delete-snapshot --region $REGION --snapshot-id $snap"
        done
    done
else
    note "No ${STACK_NAME}-orch-* AMI found. A redeploy has to re-run packer.sh, and"
    note "note that terraform destroy cannot run at all while the state still holds"
    note "resources - data.aws_ami.e2b has nothing to resolve to."
fi

# ---------------------------------------------------------------------------
# Local state on the bastion. /opt/config.properties is kept, but the sections
# steps 3 and 4 appended to it are stripped so a redeploy regenerates them
# instead of reading stale tokens.
# ---------------------------------------------------------------------------
log "local state on this host"
if $DRY_RUN; then
    note "[dry-run] remove rendered nomad/deploy/*.hcl, terraform generated files,"
    note "          /opt/.e2b-step-*.done, /tmp/nomad_env.sh, /opt/e2b-env.sh"
    note "[dry-run] strip the terraform and E2B sections from $CONFIG_FILE"
else
    find "$REPO_ROOT/nomad/deploy" -name '*-deploy.hcl' -delete 2>/dev/null
    rm -f "$TERRAFORM_DIR/var.tf" "$TERRAFORM_DIR/provider.tf" "$TERRAFORM_DIR"/tfplan*
    [ -d "$TERRAFORM_DIR/.terraform" ] && rm -r -- "$TERRAFORM_DIR/.terraform"
    rm -f "$TERRAFORM_DIR/.terraform.lock.hcl"
    rm -f /opt/.e2b-step-packer.done /opt/.e2b-step-terraform.done /opt/.e2b-step-init-db.done \
          /opt/.e2b-step-build.done /opt/.e2b-step-prepare.done /opt/.e2b-step-deploy.done \
          /opt/.e2b-step-create-template.done
    rm -f /tmp/nomad_env.sh /opt/e2b-env.sh
    rm -f "$REPO_ROOT/infra-iac/db/config.json"
    sed -i '/^# Terraform outputs added on/,$d' "$CONFIG_FILE"
    note "Kept $CONFIG_FILE with its step-1 CFN outputs; later sections stripped."
fi

log "summary"
if [ "$FAILURES" -eq 0 ]; then
    note "Completed with no failures."
    note "The CloudFormation stack is still running: NAT, Aurora (min 4 ACU), ElastiCache, this bastion."
    note "To remove it as well, run destroy-cnf.sh next - never before this script."
    exit 0
fi
note "$FAILURES step(s) failed - re-run after fixing them; every step is idempotent."
exit 1
