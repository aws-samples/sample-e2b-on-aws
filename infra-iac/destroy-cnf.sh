#!/bin/bash
# Delete the CloudFormation stack: the VPC, NAT, Aurora, ElastiCache, the four
# S3 buckets, the IAM role and this bastion instance.
#
# Run destroy.sh FIRST. Two reasons, both of which turn into a mess if ignored:
#
#   1. The Terraform state lives in s3://<e2b bucket>/terraform-state/. This
#      script empties that bucket, so anything Terraform still manages becomes
#      unreachable orphaned infrastructure - ASGs and an ALB nobody can destroy
#      by state any more. The preflight below refuses to run when the state
#      still holds resources.
#   2. AWS::S3::Bucket cannot be deleted while it holds objects, and a single
#      failed resource takes the whole stack deletion to DELETE_FAILED. Hence
#      the emptying pass here rather than a bare delete-stack.
#
# Usage:
#   destroy-cnf.sh              interactive, empties the buckets then deletes the stack
#   destroy-cnf.sh --yes        no confirmation prompt
#   destroy-cnf.sh --dry-run    print what would happen, touch nothing
#   destroy-cnf.sh --wait       block until the stack reaches DELETE_COMPLETE
#   destroy-cnf.sh --force      skip the orphaned-Terraform-state preflight
#
# This host is a stack member. Once the deletion reaches the bastion the SSM
# session ends; the stack keeps deleting server-side.

set -uo pipefail

DRY_RUN=false
ASSUME_YES=false
WAIT=false
FORCE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=true ;;
        --yes|-y)   ASSUME_YES=true ;;
        --wait)     WAIT=true ;;
        --force)    FORCE=true ;;
        -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

FAILURES=0
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

for tool in aws jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required but not installed." >&2; exit 1; }
done

CONFIG_FILE="/opt/config.properties"
[ -f "$CONFIG_FILE" ] || { echo "$CONFIG_FILE does not exist." >&2; exit 1; }

cfg() { grep -E "^$1=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-; }

REGION=$(cfg AWSREGION)
STACK_NAME=$(cfg CFNSTACKNAME)
BUCKET_E2B=$(cfg CFNE2BBUCKET)
BUCKET_TEMPLATES=$(cfg CFNTEMPLATESBUCKET)
BUCKET_BUILD_CACHE=$(cfg CFNBUILDCACHEBUCKET)
BUCKET_LOKI=$(cfg CFNLOKIBUCKET)

[ -n "$REGION" ]     || { echo "AWSREGION missing from $CONFIG_FILE." >&2; exit 1; }
[ -n "$STACK_NAME" ] || { echo "CFNSTACKNAME missing from $CONFIG_FILE." >&2; exit 1; }

STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
[ -n "$STACK_STATUS" ] || { echo "Stack $STACK_NAME not found in $REGION." >&2; exit 1; }

cat <<EOF

Region      : $REGION
Stack       : $STACK_NAME ($STACK_STATUS)
Buckets     : ${BUCKET_E2B:-?} ${BUCKET_TEMPLATES:-?} ${BUCKET_BUILD_CACHE:-?} ${BUCKET_LOKI:-?}
Mode        : $($DRY_RUN && echo "dry-run" || echo "LIVE")
EOF

# ---------------------------------------------------------------------------
# Preflight: refuse to strand Terraform-managed infrastructure.
# ---------------------------------------------------------------------------
log "preflight: Terraform state"
STATE_KEY="terraform-state/${STACK_NAME}/terraform.tfstate"
RESOURCE_COUNT=""
if [ -n "$BUCKET_E2B" ] && aws s3api head-object --bucket "$BUCKET_E2B" --key "$STATE_KEY" \
        --region "$REGION" >/dev/null 2>&1; then
    STATE_TMP="/tmp/tfstate-check.$$.json"
    if aws s3 cp "s3://$BUCKET_E2B/$STATE_KEY" "$STATE_TMP" --region "$REGION" --quiet 2>/dev/null; then
        RESOURCE_COUNT=$(jq -r '(.resources // []) | length' "$STATE_TMP" 2>/dev/null)
        rm -f "$STATE_TMP"
    fi
fi

if [ -n "$RESOURCE_COUNT" ] && [ "$RESOURCE_COUNT" != "0" ]; then
    note "s3://$BUCKET_E2B/$STATE_KEY still tracks $RESOURCE_COUNT resource(s)."
    if $FORCE; then
        note "--force given; continuing. Those resources will be orphaned - clean them up by hand."
    else
        cat >&2 <<EOF

Refusing to continue: Terraform still manages $RESOURCE_COUNT resource(s).

Emptying the buckets would delete the state that describes them, leaving the
ASGs, ALB, security groups and secrets running with no way to destroy them by
state. Run this first:

    bash $(cd "$(dirname "$0")" && pwd)/destroy.sh

Then re-run this script. Use --force only if you accept the orphans.
EOF
        exit 1
    fi
else
    note "No Terraform resources tracked${RESOURCE_COUNT:+ (count: $RESOURCE_COUNT)}; safe to proceed."
fi

if ! $DRY_RUN && ! $ASSUME_YES; then
    printf '\nThis deletes the stack, the database and this instance. Type the stack name to continue: '
    read -r reply
    [ "$reply" = "$STACK_NAME" ] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Empty the buckets. AWS::S3::Bucket deletion fails on a non-empty bucket.
# ---------------------------------------------------------------------------
log "emptying the stack-owned buckets"
for bucket in "$BUCKET_E2B" "$BUCKET_TEMPLATES" "$BUCKET_BUILD_CACHE" "$BUCKET_LOKI"; do
    [ -n "$bucket" ] || continue
    if ! aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
        note "$bucket does not exist or is not accessible; skipping."
        continue
    fi

    run aws s3 rm "s3://$bucket" --recursive --region "$REGION" --only-show-errors

    # Versioning is off on a stack created from this template, but if it was
    # ever enabled the leftover versions and delete markers still block the
    # bucket deletion.
    VERSIONING=$(aws s3api get-bucket-versioning --bucket "$bucket" --region "$REGION" \
        --query Status --output text 2>/dev/null)
    if [ "$VERSIONING" = "Enabled" ] || [ "$VERSIONING" = "Suspended" ]; then
        if $DRY_RUN; then
            note "[dry-run] purge object versions and delete markers in $bucket"
        else
            note "Purging object versions in $bucket"
            for selector in Versions DeleteMarkers; do
                while :; do
                    PAYLOAD="/tmp/s3purge.$$.json"
                    aws s3api list-object-versions --bucket "$bucket" --region "$REGION" \
                        --max-items 1000 \
                        --query "{Objects: (${selector}[] || [])[].{Key:Key,VersionId:VersionId}}" \
                        --output json > "$PAYLOAD" 2>/dev/null
                    COUNT=$(jq -r '(.Objects // []) | length' "$PAYLOAD" 2>/dev/null)
                    if [ "${COUNT:-0}" = "0" ]; then
                        rm -f "$PAYLOAD"
                        break
                    fi
                    if ! aws s3api delete-objects --bucket "$bucket" --region "$REGION" \
                            --delete "file://$PAYLOAD" --output json >/dev/null 2>&1; then
                        FAILURES=$((FAILURES + 1))
                        rm -f "$PAYLOAD"
                        break
                    fi
                    rm -f "$PAYLOAD"
                done
            done
        fi
    fi
done

# ---------------------------------------------------------------------------
# Delete the stack.
# ---------------------------------------------------------------------------
log "deleting the CloudFormation stack"
run aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

if $DRY_RUN; then
    note "[dry-run] nothing was deleted."
    exit 0
fi

note "Deletion is asynchronous. Check the status with:"
note "  aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus'"
note "Aurora and ElastiCache take the longest; expect 10-20 minutes."

if $WAIT; then
    log "waiting for DELETE_COMPLETE"
    note "This host is a stack member, so the wait usually ends when the instance"
    note "is terminated rather than when the stack finishes."
    if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null; then
        note "Stack deleted."
    else
        note "Wait ended without DELETE_COMPLETE. If the stack is DELETE_FAILED, the"
        note "usual cause is a bucket that received new objects after the emptying"
        note "pass - empty it and delete the stack again."
        FAILURES=$((FAILURES + 1))
    fi
fi

log "summary"
if [ "$FAILURES" -eq 0 ]; then
    note "Completed with no failures."
    exit 0
fi
note "$FAILURES step(s) failed; re-running is safe."
exit 1
