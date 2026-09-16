#!/usr/bin/env bash
set -Eeuo pipefail

# Convert the root filesystem of an EBS-backed AMI into a Docker image without
# launching the AMI.
#
# Flow:
#   AMI -> root EBS snapshot -> temporary EBS volume -> attach to selected EC2
#       -> read-only mount -> tar stream -> docker import -> detach/delete
#
# IMPORTANT:
#   Run this script on the EC2 instance selected by <target-instance-id>.
#   The target instance is never auto-detected; you must choose it explicitly.
#
# Usage:
#   ./tools/ami-to-docker.sh \
#     ami-0123456789abcdef0 \
#     i-0123456789abcdef0 \
#     my-image:latest
#
# Optional environment variables:
#   AWS_REGION=ap-northeast-1   AWS region containing the AMI and target EC2.
#                               Falls back to AWS_DEFAULT_REGION / AWS CLI config.
#   KEEP_VOLUME=1               Keep the temporary EBS volume after completion.
#   VOLUME_TYPE=gp3             Temporary EBS volume type (default: gp3).
#   ATTACH_DEVICE=/dev/sdf      AWS API attachment name (default: /dev/sdf).
#
# Requirements:
#   aws cli, docker, GNU tar, lsblk, mount/umount
#
# Notes:
#   - The target EC2 instance must be in the same Availability Zone as the
#     temporary EBS volume. This script creates the volume in the target AZ.
#   - Nitro instances expose EBS volumes as NVMe devices even when /dev/sdf is
#     requested. The script resolves the real block device from the EBS volume
#     ID instead of assuming a Linux device name.
#   - Standard ext2/3/4, XFS, and Btrfs root filesystems are supported.
#   - LVM-backed AMIs are intentionally rejected instead of activating a VG on
#     the host implicitly.

usage() {
  cat <<'EOF'
Usage:
  ami-to-docker.sh <ami-id> <target-instance-id> <docker-image[:tag]>

Example:
  ./tools/ami-to-docker.sh \
    ami-0123456789abcdef0 \
    i-0123456789abcdef0 \
    ubuntu-from-ami:latest

The target EC2 instance is always explicit. There is no automatic current-instance
selection. Run this script on the same EC2 instance you pass as target-instance-id,
because the mounted EBS block device and Docker daemon are accessed locally.

Environment:
  AWS_REGION=ap-northeast-1
  KEEP_VOLUME=1
  VOLUME_TYPE=gp3
  ATTACH_DEVICE=/dev/sdf
EOF
}

log() {
  printf '==> %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for cmd in aws docker tar lsblk mount umount awk sort grep; do
  require_command "$cmd"
done

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

AMI_ID="$1"
TARGET_INSTANCE_ID="$2"
IMAGE="$3"
VOLUME_TYPE="${VOLUME_TYPE:-gp3}"
ATTACH_DEVICE="${ATTACH_DEVICE:-/dev/sdf}"
KEEP_VOLUME="${KEEP_VOLUME:-0}"

[[ "$AMI_ID" == ami-* ]] || die "invalid AMI id: $AMI_ID"
[[ "$TARGET_INSTANCE_ID" == i-* ]] || die "invalid target EC2 instance id: $TARGET_INSTANCE_ID"
[[ -n "$IMAGE" ]] || die "Docker image name must not be empty"
[[ "$KEEP_VOLUME" == 0 || "$KEEP_VOLUME" == 1 ]] || die "KEEP_VOLUME must be 0 or 1"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$REGION" ]]; then
  REGION="$(aws configure get region 2>/dev/null || true)"
fi
[[ -n "$REGION" ]] || die "AWS region is not configured; set AWS_REGION or configure a default region"

MOUNT_DIR="$(mktemp -d /tmp/ami-to-docker.XXXXXX)"
VOLUME_ID=""
BLOCK_DEVICE=""
ROOT_FS_DEVICE=""
MOUNTED=0
ATTACHED=0

cleanup() {
  local rc=$?
  set +e

  if [[ "$MOUNTED" == 1 ]]; then
    log "Unmounting $MOUNT_DIR"
    sudo umount "$MOUNT_DIR"
    MOUNTED=0
  fi

  if [[ -n "$VOLUME_ID" && "$ATTACHED" == 1 ]]; then
    log "Detaching temporary EBS volume $VOLUME_ID"
    aws ec2 detach-volume \
      --region "$REGION" \
      --volume-id "$VOLUME_ID" \
      >/dev/null 2>&1 || true

    aws ec2 wait volume-available \
      --region "$REGION" \
      --volume-ids "$VOLUME_ID" \
      >/dev/null 2>&1 || true

    ATTACHED=0
  fi

  if [[ -n "$VOLUME_ID" ]]; then
    if [[ "$KEEP_VOLUME" == 1 ]]; then
      log "Keeping temporary EBS volume: $VOLUME_ID"
    else
      log "Deleting temporary EBS volume $VOLUME_ID"
      aws ec2 delete-volume \
        --region "$REGION" \
        --volume-id "$VOLUME_ID" \
        >/dev/null 2>&1 || true
    fi
  fi

  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

log "Reading selected target instance"
read -r AZ INSTANCE_STATE < <(
  aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$TARGET_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[Placement.AvailabilityZone,State.Name]' \
    --output text
)

[[ -n "$AZ" && "$AZ" != None ]] || die "target EC2 instance not found in $REGION: $TARGET_INSTANCE_ID"
[[ "$INSTANCE_STATE" == running ]] || die "target EC2 instance must be running; current state: $INSTANCE_STATE"

log "Target instance: $TARGET_INSTANCE_ID"
log "Region:          $REGION"
log "AZ:              $AZ"

log "Reading AMI root snapshot"
read -r ROOT_DEVICE ROOT_TYPE ARCHITECTURE < <(
  aws ec2 describe-images \
    --region "$REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].[RootDeviceName,RootDeviceType,Architecture]' \
    --output text
)

[[ -n "$ROOT_DEVICE" && "$ROOT_DEVICE" != None ]] || die "AMI not found or root device missing: $AMI_ID"
[[ "$ROOT_TYPE" == ebs ]] || die "AMI root device is not EBS-backed: $ROOT_TYPE"

SNAPSHOT_ID="$(aws ec2 describe-images \
  --region "$REGION" \
  --image-ids "$AMI_ID" \
  --query "Images[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE}'].Ebs.SnapshotId | [0]" \
  --output text)"

[[ -n "$SNAPSHOT_ID" && "$SNAPSHOT_ID" != None ]] || die "root EBS snapshot not found for $AMI_ID"

case "$ARCHITECTURE" in
  x86_64) PLATFORM='linux/amd64' ;;
  arm64)  PLATFORM='linux/arm64' ;;
  i386)   PLATFORM='linux/386' ;;
  *) die "unsupported AMI architecture: $ARCHITECTURE" ;;
esac

log "AMI root device: $ROOT_DEVICE"
log "Root snapshot:   $SNAPSHOT_ID"
log "Architecture:    $ARCHITECTURE ($PLATFORM)"

log "Creating temporary $VOLUME_TYPE EBS volume from $SNAPSHOT_ID"
VOLUME_ID="$(aws ec2 create-volume \
  --region "$REGION" \
  --snapshot-id "$SNAPSHOT_ID" \
  --availability-zone "$AZ" \
  --volume-type "$VOLUME_TYPE" \
  --tag-specifications \
    "ResourceType=volume,Tags=[{Key=Name,Value=ami-to-docker-temp},{Key=ami-to-docker-source,Value=${AMI_ID}},{Key=ami-to-docker-target,Value=${TARGET_INSTANCE_ID}}]" \
  --query VolumeId \
  --output text)"

[[ -n "$VOLUME_ID" && "$VOLUME_ID" == vol-* ]] || die "failed to create EBS volume"
log "Temporary volume: $VOLUME_ID"

aws ec2 wait volume-available \
  --region "$REGION" \
  --volume-ids "$VOLUME_ID"

log "Attaching $VOLUME_ID to selected instance $TARGET_INSTANCE_ID as $ATTACH_DEVICE"
aws ec2 attach-volume \
  --region "$REGION" \
  --volume-id "$VOLUME_ID" \
  --instance-id "$TARGET_INSTANCE_ID" \
  --device "$ATTACH_DEVICE" \
  >/dev/null
ATTACHED=1

aws ec2 wait volume-in-use \
  --region "$REGION" \
  --volume-ids "$VOLUME_ID"

# Nitro exposes EBS volumes as /dev/nvme*n1 and puts the EBS volume id, without
# the hyphen, in the NVMe serial. Older Xen instances normally expose /dev/xvd*.
SERIAL="${VOLUME_ID//-/}"
log "Resolving attached Linux block device"

for _ in $(seq 1 60); do
  BLOCK_DEVICE="$(lsblk -dn -o NAME,SERIAL 2>/dev/null \
    | awk -v serial="$SERIAL" '$2 == serial {print "/dev/" $1; exit}')"

  if [[ -n "$BLOCK_DEVICE" && -b "$BLOCK_DEVICE" ]]; then
    break
  fi

  attach_basename="${ATTACH_DEVICE#/dev/}"
  xen_device="/dev/xvd${attach_basename#sd}"
  if [[ -b "$xen_device" ]]; then
    BLOCK_DEVICE="$xen_device"
    break
  fi

  if [[ -b "$ATTACH_DEVICE" ]]; then
    BLOCK_DEVICE="$ATTACH_DEVICE"
    break
  fi

  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle >/dev/null 2>&1 || true
  sleep 1
done

[[ -n "$BLOCK_DEVICE" && -b "$BLOCK_DEVICE" ]] || {
  lsblk -o NAME,SIZE,FSTYPE,TYPE,SERIAL,MOUNTPOINTS >&2 || true
  die "could not see $VOLUME_ID locally. Run this script on the selected target EC2 instance: $TARGET_INSTANCE_ID"
}

log "Attached block device: $BLOCK_DEVICE"
lsblk -f "$BLOCK_DEVICE" >&2

# Refuse LVM automatically. Activating cloned VGs can collide with host VG/LV
# names and UUIDs. It is safer to make that an explicit future feature.
if lsblk -nrpo FSTYPE "$BLOCK_DEVICE" | grep -qx 'LVM2_member'; then
  die "LVM-backed root filesystems are not supported automatically"
fi

# The AMI root disk may be partitioned (for example: EFI + root). Pick the
# largest filesystem from the attached disk among the supported Linux types.
ROOT_FS_DEVICE="$(lsblk -b -nrpo NAME,FSTYPE,SIZE "$BLOCK_DEVICE" \
  | awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ { print $1, $3 }' \
  | sort -k2,2nr \
  | awk 'NR == 1 { print $1 }')"

[[ -n "$ROOT_FS_DEVICE" && -b "$ROOT_FS_DEVICE" ]] || {
  lsblk -f "$BLOCK_DEVICE" >&2 || true
  die "could not find a supported root filesystem on $BLOCK_DEVICE"
}

FSTYPE="$(lsblk -dn -o FSTYPE "$ROOT_FS_DEVICE")"
log "Root filesystem: $ROOT_FS_DEVICE ($FSTYPE)"

log "Mounting root filesystem read-only at $MOUNT_DIR"
case "$FSTYPE" in
  ext2|ext3|ext4)
    # noload prevents journal replay from writing to the temporary EBS volume.
    sudo mount -t "$FSTYPE" -o ro,noload "$ROOT_FS_DEVICE" "$MOUNT_DIR"
    ;;
  xfs)
    # Snapshot copies can share the source filesystem UUID. nouuid avoids a
    # duplicate-UUID mount failure; norecovery keeps the mount read-only.
    sudo mount -t xfs -o ro,nouuid,norecovery "$ROOT_FS_DEVICE" "$MOUNT_DIR"
    ;;
  btrfs)
    sudo mount -t btrfs -o ro "$ROOT_FS_DEVICE" "$MOUNT_DIR"
    ;;
  *)
    die "unsupported filesystem: $FSTYPE"
    ;;
esac
MOUNTED=1

# Sanity check: avoid importing an accidentally selected boot/EFI partition.
[[ -d "$MOUNT_DIR/etc" && -d "$MOUNT_DIR/usr" ]] || \
  die "mounted filesystem does not look like a Linux root filesystem"

log "Importing filesystem as Docker image $IMAGE"
sudo tar \
  --numeric-owner \
  --acls \
  --xattrs \
  --xattrs-include='*' \
  --one-file-system \
  --exclude='./proc/*' \
  --exclude='./sys/*' \
  --exclude='./dev/*' \
  --exclude='./run/*' \
  --exclude='./tmp/*' \
  --exclude='./var/lib/docker/*' \
  --exclude='./var/lib/containerd/*' \
  -C "$MOUNT_DIR" \
  -cpf - . \
| docker image import \
    --platform "$PLATFORM" \
    --change 'CMD ["/bin/bash"]' \
    - "$IMAGE"

log "Docker image created successfully"
docker image inspect "$IMAGE" \
  --format 'Image={{index .RepoTags 0}} OS={{.Os}} Arch={{.Architecture}} Size={{.Size}}'
