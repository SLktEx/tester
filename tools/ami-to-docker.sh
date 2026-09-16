#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare every EBS-backed filesystem captured by an AMI for manual conversion
# on an existing EC2 instance.
#
# This script runs on your local machine and only uses the AWS API:
#   AMI -> all EBS snapshots -> EBS volumes -> attach to selected EC2 -> stop
#
# It does NOT SSH into the instance, mount filesystems, or run Docker.
#
# Usage:
#   ./tools/ami-to-docker.sh <ami-id> <target-instance-id>
#
# Example:
#   AWS_REGION=ap-northeast-1 \
#     ./tools/ami-to-docker.sh \
#       ami-0123456789abcdef0 \
#       i-0123456789abcdef0
#
# Environment:
#   AWS_REGION=ap-northeast-1  Region containing both the AMI and target EC2.
#                              Falls back to AWS_DEFAULT_REGION / AWS CLI config.
#   VOLUME_TYPE=gp3            Optional override applied to every created EBS
#                              volume. If omitted, each AMI mapping's original
#                              volume type is preserved.
#
# Requirements:
#   aws cli with permissions for DescribeImages, DescribeInstances,
#   CreateVolume, tag-on-create, AttachVolume, and EC2/EBS waiters.

usage() {
  cat <<'EOF'
Usage:
  ami-to-docker.sh <ami-id> <target-instance-id>

Example:
  AWS_REGION=ap-northeast-1 \
    ./tools/ami-to-docker.sh ami-0123456789abcdef0 i-0123456789abcdef0

What it does:
  1. Finds every EBS snapshot in the AMI block-device mappings.
  2. Finds the selected EC2 instance's Availability Zone.
  3. Creates one EBS volume per AMI snapshot in that AZ.
  4. Attaches every created volume to the selected EC2 instance.
  5. Prints source-device -> snapshot -> volume -> attachment-device mappings.

It does NOT mount the EBS volumes or run Docker.
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
VOLUME_TYPE_OVERRIDE="${VOLUME_TYPE:-}"

[[ "$AMI_ID" == ami-* ]] || die "invalid AMI id: $AMI_ID"
[[ "$TARGET_INSTANCE_ID" == i-* ]] || die "invalid EC2 instance id: $TARGET_INSTANCE_ID"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$REGION" ]]; then
  REGION="$(aws configure get region 2>/dev/null || true)"
fi
[[ -n "$REGION" ]] || \
  die "AWS region is not configured; set AWS_REGION or configure a default region"

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
  *) die "target EC2 instance cannot accept volumes in state: $INSTANCE_STATE" ;;
esac

log "Target instance: $TARGET_INSTANCE_ID"
log "State:           $INSTANCE_STATE"
log "Region:          $REGION"
log "AZ:              $AZ"

log "Reading AMI block-device mappings"
read -r ROOT_DEVICE ROOT_TYPE < <(
  aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].[RootDeviceName,RootDeviceType]' \
    --output text
)

[[ -n "$ROOT_DEVICE" && "$ROOT_DEVICE" != None ]] || \
  die "AMI not found or root device missing: $AMI_ID"
[[ "$ROOT_TYPE" == ebs ]] || \
  die "AMI root device is not EBS-backed: $ROOT_TYPE"

# One line per EBS-backed AMI mapping:
#   source-device snapshot-id volume-type volume-size iops throughput
# Ephemeral/instance-store mappings and NoDevice entries are intentionally
# ignored because they have no EBS snapshot to restore.
mapfile -t AMI_MAPPINGS < <(
  aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].BlockDeviceMappings[?Ebs.SnapshotId!=`null`].[DeviceName,Ebs.SnapshotId,Ebs.VolumeType,Ebs.VolumeSize,Ebs.Iops,Ebs.Throughput]' \
    --output text
)

[[ ${#AMI_MAPPINGS[@]} -gt 0 ]] || \
  die "AMI has no EBS snapshots: $AMI_ID"

log "AMI:             $AMI_ID"
log "AMI root device: $ROOT_DEVICE"
log "EBS snapshots:   ${#AMI_MAPPINGS[@]}"

# Read the target's currently occupied API-level device names once and reserve
# free names from /dev/sdf through /dev/sdp for the volumes we are about to add.
declare -A USED_DEVICES=()
while IFS= read -r current; do
  [[ -n "$current" && "$current" != None ]] || continue
  USED_DEVICES["$current"]=1

  # Treat the sdX/xvdX aliases as equivalent for collision avoidance.
  if [[ "$current" =~ ^/dev/sd([a-z]+)$ ]]; then
    USED_DEVICES["/dev/xvd${BASH_REMATCH[1]}"]=1
  elif [[ "$current" =~ ^/dev/xvd([a-z]+)$ ]]; then
    USED_DEVICES["/dev/sd${BASH_REMATCH[1]}"]=1
  fi
done < <(
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$TARGET_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[].DeviceName' \
    --output text | tr '\t' '\n'
)

AVAILABLE_DEVICES=()
for suffix in f g h i j k l m n o p; do
  candidate="/dev/sd${suffix}"
  if [[ -z "${USED_DEVICES[$candidate]:-}" && -z "${USED_DEVICES[/dev/xvd${suffix}]:-}" ]]; then
    AVAILABLE_DEVICES+=("$candidate")
  fi
done

if (( ${#AVAILABLE_DEVICES[@]} < ${#AMI_MAPPINGS[@]} )); then
  die "AMI has ${#AMI_MAPPINGS[@]} EBS snapshots but only ${#AVAILABLE_DEVICES[@]} free attachment names are available from /dev/sdf through /dev/sdp"
fi

CREATED_VOLUMES=()
SOURCE_DEVICES_OUT=()
SNAPSHOTS_OUT=()
VOLUMES_OUT=()
ATTACH_DEVICES_OUT=()

cleanup_failed_create() {
  local rc=$?
  trap - EXIT

  if [[ $rc -ne 0 && ${#CREATED_VOLUMES[@]} -gt 0 ]]; then
    printf '\nERROR: the operation stopped after creating EBS volume(s).\n' >&2
    printf 'Nothing was deleted automatically. Inspect these volumes before cleanup:\n' >&2
    printf '  %s\n' "${CREATED_VOLUMES[@]}" >&2
  fi

  exit "$rc"
}
trap cleanup_failed_create EXIT

for index in "${!AMI_MAPPINGS[@]}"; do
  mapping="${AMI_MAPPINGS[$index]}"
  read -r SOURCE_DEVICE SNAPSHOT_ID SOURCE_VOLUME_TYPE SOURCE_VOLUME_SIZE SOURCE_IOPS SOURCE_THROUGHPUT <<<"$mapping"

  [[ "$SNAPSHOT_ID" == snap-* ]] || \
    die "invalid snapshot id in AMI mapping for $SOURCE_DEVICE: $SNAPSHOT_ID"

  DEVICE="${AVAILABLE_DEVICES[$index]}"
  VOLUME_TYPE="${VOLUME_TYPE_OVERRIDE:-$SOURCE_VOLUME_TYPE}"

  [[ -n "$VOLUME_TYPE" && "$VOLUME_TYPE" != None ]] || VOLUME_TYPE=gp3

  create_args=(
    ec2 create-volume
    --region "$REGION"
    --snapshot-id "$SNAPSHOT_ID"
    --availability-zone "$AZ"
    --volume-type "$VOLUME_TYPE"
  )

  # Respect an AMI mapping that expanded the volume beyond its snapshot's
  # original size.
  if [[ -n "$SOURCE_VOLUME_SIZE" && "$SOURCE_VOLUME_SIZE" != None ]]; then
    create_args+=(--size "$SOURCE_VOLUME_SIZE")
  fi

  # When preserving the AMI's original volume type, also preserve tunables that
  # are represented in the AMI mapping. If VOLUME_TYPE overrides the type, AWS
  # defaults are used for the new type instead of applying incompatible values.
  if [[ -z "$VOLUME_TYPE_OVERRIDE" ]]; then
    case "$SOURCE_VOLUME_TYPE" in
      gp3)
        if [[ -n "$SOURCE_IOPS" && "$SOURCE_IOPS" != None ]]; then
          create_args+=(--iops "$SOURCE_IOPS")
        fi
        if [[ -n "$SOURCE_THROUGHPUT" && "$SOURCE_THROUGHPUT" != None ]]; then
          create_args+=(--throughput "$SOURCE_THROUGHPUT")
        fi
        ;;
      io1|io2)
        if [[ -n "$SOURCE_IOPS" && "$SOURCE_IOPS" != None ]]; then
          create_args+=(--iops "$SOURCE_IOPS")
        fi
        ;;
    esac
  fi

  create_args+=(
    --tag-specifications
    "ResourceType=volume,Tags=[{Key=Name,Value=ami-to-docker-${index}},{Key=ami-to-docker-source,Value=${AMI_ID}},{Key=ami-to-docker-target,Value=${TARGET_INSTANCE_ID}},{Key=ami-source-device,Value=${SOURCE_DEVICE}},{Key=ami-source-snapshot,Value=${SNAPSHOT_ID}}]"
    --query VolumeId
    --output text
  )

  log "[$((index + 1))/${#AMI_MAPPINGS[@]}] Creating $VOLUME_TYPE EBS volume from $SNAPSHOT_ID ($SOURCE_DEVICE)"
  VOLUME_ID="$(aws "${create_args[@]}")"
  [[ "$VOLUME_ID" == vol-* ]] || die "failed to create EBS volume from $SNAPSHOT_ID"
  CREATED_VOLUMES+=("$VOLUME_ID")

  log "Waiting for $VOLUME_ID to become available"
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

  log "Waiting for $VOLUME_ID attachment to complete"
  aws ec2 wait volume-in-use \
    --region "$REGION" \
    --volume-ids "$VOLUME_ID"

  SOURCE_DEVICES_OUT+=("$SOURCE_DEVICE")
  SNAPSHOTS_OUT+=("$SNAPSHOT_ID")
  VOLUMES_OUT+=("$VOLUME_ID")
  ATTACH_DEVICES_OUT+=("$DEVICE")
done

trap - EXIT

printf '\nAttached all AMI EBS snapshots successfully.\n\n'
printf 'AMI:          %s\n' "$AMI_ID"
printf 'EC2 instance: %s\n' "$TARGET_INSTANCE_ID"
printf 'AZ:           %s\n' "$AZ"
printf 'Volumes:      %s\n\n' "${#VOLUMES_OUT[@]}"
printf '%-14s %-24s %-24s %-12s\n' 'AMI device' 'Snapshot' 'New volume' 'AWS device'
printf '%-14s %-24s %-24s %-12s\n' '----------' '--------' '----------' '----------'
for index in "${!VOLUMES_OUT[@]}"; do
  printf '%-14s %-24s %-24s %-12s\n' \
    "${SOURCE_DEVICES_OUT[$index]}" \
    "${SNAPSHOTS_OUT[$index]}" \
    "${VOLUMES_OUT[$index]}" \
    "${ATTACH_DEVICES_OUT[$index]}"
done

cat <<EOF

Next, log in to $TARGET_INSTANCE_ID and run lsblk to find the actual Linux block devices.
On Nitro instances they will usually appear as /dev/nvme*n1 rather than the /dev/sdX names above.

This script intentionally leaves every created EBS volume attached and does not delete them.
EOF
