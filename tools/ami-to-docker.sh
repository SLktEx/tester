#!/usr/bin/env bash
set -Eeuo pipefail

# Convert the root filesystem of an EBS-backed AMI into a Docker image without
# launching the AMI.
#
# Flow:
#   AMI -> root EBS snapshot -> temporary EBS volume -> attach to this EC2
#       -> read-only mount -> tar stream -> docker import -> detach/delete
#
# Usage:
#   ./tools/ami-to-docker.sh ami-0123456789abcdef0 my-image:latest
#
# Optional environment variables:
#   AWS_REGION=ap-northeast-1   Override region detection.
#   TARGET_INSTANCE_ID=i-...    Attach to a specific EC2 instance instead of
#                               the current instance discovered through IMDSv2.
#   KEEP_VOLUME=1               Keep the temporary EBS volume after completion.
#   VOLUME_TYPE=gp3             Temporary EBS volume type (default: gp3).
#   ATTACH_DEVICE=/dev/sdf      AWS API attachment name (default: /dev/sdf).
#
# Requirements:
#   aws cli, docker, GNU tar, curl, lsblk, mount/umount
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
  ami-to-docker.sh <ami-id> <docker-image[:tag]>

Example:
  ./tools/ami-to-docker.sh ami-0123456789abcdef0 ubuntu-from-ami:latest

Environment:
  AWS_REGION            AWS region override
  TARGET_INSTANCE_ID    EC2 instance that receives the temporary EBS volume
  KEEP_VOLUME=1         Do not delete the temporary EBS volume
  VOLUME_TYPE=gp3       Temporary EBS volume type
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

for cmd in aws docker tar curl lsblk mount umount awk sort sed grep; do
  require_command "$cmd"
done

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

AMI_ID="$1"
IMAGE="$2"
VOLUME_TYPE="${VOLUME_TYPE:-gp3}"
ATTACH_DEVICE="${ATTACH_DEVICE:-/dev/sdf}"
KEEP_VOLUME="${KEEP_VOLUME:-0}"

[[ "$AMI_ID" == ami-* ]] || die "invalid AMI id: $AMI_ID"
[[ -n "$IMAGE" ]] || die "Docker image name must not be empty"
[[ "$KEEP_VOLUME" == 0 || "$KEEP_VOLUME" == 1 ]] || die "KEEP_VOLUME must be 0 or 1"

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

# Fetch an IMDSv2 token only if metadata is needed. This keeps TARGET_INSTANCE_ID
# usable from automation that already knows the destination instance.
IMDS_TOKEN=""
imds_token() {
  if [[ -z "$IMDS_TOKEN" ]]; then
    IMDS_TOKEN="$(curl -fsS --connect-timeout 2 --max-time 5 \
      -X PUT \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
      http://169.254.169.254/latest/api/token)" \
      || die "failed to obtain an EC2 IMDSv2 token"
  fi
  printf '%s' "$IMDS_TOKEN"
}

imds_get() {
  local path="$1"
  local token
  token="$(imds_token)"
  curl -fsS --connect-timeout 2 --max-time 5 \
    -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$path"
}

if [[ -z "${TARGET_INSTANCE_ID:-}" ]]; then
  log "Detecting current EC2 instance through IMDSv2"
  TARGET_INSTANCE_ID="$(imds_get instance-id)" \
    || die "failed to detect current EC2 instance id"
fi

if [[ -z "${AWS_REGION:-}" ]]; then
  # placement/region is available through IMDS on modern EC2. If the caller
  # supplied TARGET_INSTANCE_ID while running on that EC2, this avoids relying
  # on local AWS CLI config.
  AWS_REGION="$(imds_get placement/region 2>/dev/null || true)"
fi

# If region is still unknown, let the AWS CLI resolve it from its normal config
# and then read the target instance's AZ. A missing CLI region will fail here
# with the normal AWS error instead of producing an incorrect region.
REGION="${AWS_REGION:-}"

aws_region_args=()
if [[ -n "$REGION" ]]; then
  aws_region_args=(--region "$REGION")
fi

log "Reading target instance placement"
AZ="$(aws ec2 describe-instances \
  "${aws_region_args[@]}" \
  --instance-ids "$TARGET_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
  --output text)"

[[ -n "$AZ" && "$AZ" != None ]] || die "could not determine Availability Zone for $TARGET_INSTANCE_ID"

if [[ -z "$REGION" ]]; then
  # Availability Zones normally end in a letter, but local/wavelength zones do
  # not follow a simple suffix rule. Ask the EC2 API for the region explicitly.
  REGION="$(aws ec2 describe-availability-zones \
    --zone-names "$AZ" \
    --query 'AvailabilityZones[0].RegionName' \
    --output text)"
  [[ -n "$REGION" && "$REGION" != None ]] || die "could not determine region for AZ $AZ"
fi

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
    "ResourceType=volume,Tags=[{Key=Name,Value=ami-to-docker-temp},{Key=ami-to-docker-source,Value=${AMI_ID}}]" \
  --query VolumeId \
  --output text)"

[[ -n "$VOLUME_ID" && "$VOLUME_ID" == vol-* ]] || die "failed to create EBS volume"
log "Temporary volume: $VOLUME_ID"

aws ec2 wait volume-available \
  --region "$REGION" \
  --volume-ids "$VOLUME_ID"

log "Attaching $VOLUME_ID to $TARGET_INSTANCE_ID as $ATTACH_DEVICE"
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

  # Xen device naming fallback. /dev/sdf may also appear as /dev/xvdf.
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
  die "could not resolve Linux device for $VOLUME_ID"
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
