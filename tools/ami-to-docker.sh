#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare the root filesystem of an EBS-backed AMI for manual conversion on an
# existing EC2 instance.
#
# This script is intentionally local-only: it uses the AWS API to find the AMI
# root snapshot, creates an EBS volume in the target instance's Availability
# Zone, and attaches that volume to the selected EC2 instance. It does NOT SSH
# into the instance, mount the filesystem, or run Docker.
#
# Flow:
#   local machine
#     -> AMI root snapshot
#     -> create EBS in target EC2 AZ
#     -> attach EBS to selected EC2
#     -> stop
#
# Usage:
#   ./tools/ami-to-docker.sh <ami-id> <target-instance-id>
#
# Example:
#   ./tools/ami-to-docker.sh \
#     ami-0123456789abcdef0 \
#     i-0123456789abcdef0
#
# Environment:
#   AWS_REGION=ap-northeast-1  Region containing both the AMI and target EC2.
#                              Falls back to AWS_DEFAULT_REGION / AWS CLI config.
#   VOLUME_TYPE=gp3            EBS type to create (default: gp3).
#   ATTACH_DEVICE=/dev/sdf     AWS attachment name. If omitted, the first free
#                              name from /dev/sdf through /dev/sdp is selected.
#
# Requirements:
#   aws cli with permissions for DescribeImages, DescribeInstances,
#   CreateVolume, CreateTags/Tag-on-create, AttachVolume, and EBS waiters.

usage() {
  cat <<'EOF'
Usage:
  ami-to-docker.sh <ami-id> <target-instance-id>

Example:
  AWS_REGION=ap-northeast-1 \
    ./tools/ami-to-docker.sh ami-0123456789abcdef0 i-0123456789abcdef0

What it does:
  1. Finds the AMI root EBS snapshot.
  2. Finds the selected EC2 instance's Availability Zone.
  3. Creates an EBS volume from the snapshot in that AZ.
  4. Attaches the EBS volume to the selected EC2 instance.
  5. Prints the IDs/device name and exits.

It does NOT mount the EBS volume or run Docker.
EOF
}

log() {
  printf '==> %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v aws >/dev/null 2>&1 || die "required command not found: aws"

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

AMI_ID="$1"
TARGET_INSTANCE_ID="$2"
VOLUME_TYPE="${VOLUME_TYPE:-gp3}"

[[ "$AMI_ID" == ami-* ]] || die "invalid AMI id: $AMI_ID"
[[ "$TARGET_INSTANCE_ID" == i-* ]] || die "invalid EC2 instance id: $TARGET_INSTANCE_ID"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$REGION" ]]; then
  REGION="$(aws configure get region 2>/dev/null || true)"
fi
[[ -n "$REGION" ]] || die "AWS region is not configured; set AWS_REGION or configure a default region"

log "Reading target EC2 instance"
read -r AZ INSTANCE_STATE < <(
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$TARGET_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[Placement.AvailabilityZone,State.Name]' \
    --output text
)

[[ -n "$AZ" && "$AZ" != None ]] || \
  die "target EC2 instance not found in $REGION: $TARGET_INSTANCE_ID"

case "$INSTANCE_STATE" in
  running|stopped) ;;
  *) die "target EC2 instance cannot accept the volume in state: $INSTANCE_STATE" ;;
esac

log "Target instance: $TARGET_INSTANCE_ID"
log "State:           $INSTANCE_STATE"
log "Region:          $REGION"
log "AZ:              $AZ"

log "Reading AMI root EBS snapshot"
read -r ROOT_DEVICE ROOT_TYPE SNAPSHOT_ID < <(
  aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].[RootDeviceName,RootDeviceType,BlockDeviceMappings[?DeviceName==`'"'"'"'"'"'"'`].Ebs.SnapshotId | [0]]' \
    --output text 2>/dev/null || true
)

# The nested JMESPath above is awkward to parameterize portably, so fetch the
# root metadata and snapshot separately when necessary.
if [[ -z "${ROOT_DEVICE:-}" || "$ROOT_DEVICE" == None ]]; then
  read -r ROOT_DEVICE ROOT_TYPE < <(
    aws ec2 describe-images \
      --region "$REGION" \
      --image-ids "$AMI_ID" \
      --query 'Images[0].[RootDeviceName,RootDeviceType]' \
      --output text
  )
fi

[[ -n "$ROOT_DEVICE" && "$ROOT_DEVICE" != None ]] || \
  die "AMI not found or root device missing: $AMI_ID"
[[ "$ROOT_TYPE" == ebs ]] || \
  die "AMI root device is not EBS-backed: $ROOT_TYPE"

SNAPSHOT_ID="$(
  aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query "Images[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE}'].Ebs.SnapshotId | [0]" \
    --output text
)"

[[ -n "$SNAPSHOT_ID" && "$SNAPSHOT_ID" != None ]] || \
  die "root EBS snapshot not found for $AMI_ID"

log "AMI:             $AMI_ID"
log "AMI root device: $ROOT_DEVICE"
log "Root snapshot:   $SNAPSHOT_ID"

if [[ -n "${ATTACH_DEVICE:-}" ]]; then
  DEVICE="$ATTACH_DEVICE"
else
  # Pick a free API-level EBS device name. On Nitro, Linux will normally expose
  # the volume as /dev/nvme*n1 instead; this name is still used for AttachVolume.
  mapfile -t USED_DEVICES < <(
    aws ec2 describe-instances \
      --region "$REGION" \
      --instance-ids "$TARGET_INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].BlockDeviceMappings[].DeviceName' \
      --output text | tr '\t' '\n'
  )

  DEVICE=""
  for suffix in f g h i j k l m n o p; do
    candidate="/dev/sd${suffix}"
    used=0
    for current in "${USED_DEVICES[@]:-}"; do
      if [[ "$current" == "$candidate" || "$current" == "/dev/xvd${suffix}" ]]; then
        used=1
        break
      fi
    done
    if [[ "$used" == 0 ]]; then
      DEVICE="$candidate"
      break
    fi
  done

  [[ -n "$DEVICE" ]] || \
    die "no free attachment name found from /dev/sdf through /dev/sdp; set ATTACH_DEVICE explicitly"
fi

[[ "$DEVICE" == /dev/* ]] || die "ATTACH_DEVICE must be a /dev/... path"

VOLUME_ID=""
cleanup_failed_create() {
  local rc=$?
  if [[ $rc -ne 0 && -n "$VOLUME_ID" ]]; then
    printf '\nERROR: volume %s was created but the operation did not finish.\n' "$VOLUME_ID" >&2
    printf 'It was NOT deleted automatically. Inspect it before cleanup.\n' >&2
  fi
  exit "$rc"
}
trap cleanup_failed_create EXIT

log "Creating $VOLUME_TYPE EBS volume from $SNAPSHOT_ID in $AZ"
VOLUME_ID="$(
  aws ec2 create-volume \
    --region "$REGION" \
    --snapshot-id "$SNAPSHOT_ID" \
    --availability-zone "$AZ" \
    --volume-type "$VOLUME_TYPE" \
    --tag-specifications \
      "ResourceType=volume,Tags=[{Key=Name,Value=ami-to-docker},{Key=ami-to-docker-source,Value=${AMI_ID}},{Key=ami-to-docker-target,Value=${TARGET_INSTANCE_ID}}]" \
    --query VolumeId \
    --output text
)"

[[ "$VOLUME_ID" == vol-* ]] || die "failed to create EBS volume"

log "Created volume: $VOLUME_ID"
log "Waiting for volume to become available"
aws ec2 wait volume-available \
  --region "$REGION" \
  --volume-ids "$VOLUME_ID"

log "Attaching $VOLUME_ID to $TARGET_INSTANCE_ID as $DEVICE"
aws ec2 attach-volume \
  --region "$REGION" \
  --volume-id "$VOLUME_ID" \
  --instance-id "$TARGET_INSTANCE_ID" \
  --device "$DEVICE" \
  >/dev/null

log "Waiting for attachment to complete"
aws ec2 wait volume-in-use \
  --region "$REGION" \
  --volume-ids "$VOLUME_ID"

trap - EXIT

cat <<EOF

Attached successfully.

AMI:          $AMI_ID
Snapshot:     $SNAPSHOT_ID
Volume:       $VOLUME_ID
EC2 instance: $TARGET_INSTANCE_ID
AZ:           $AZ
AWS device:   $DEVICE

Next, log in to $TARGET_INSTANCE_ID and use lsblk to find the actual Linux block device.
On Nitro instances it will usually appear as /dev/nvme*n1 rather than $DEVICE.

This script intentionally leaves the EBS volume attached and does not delete it.
EOF
