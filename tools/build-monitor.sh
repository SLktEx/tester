#!/usr/bin/env bash
set -uo pipefail

# Monitor a long-running build and record enough system metrics to diagnose
# sustained-performance degradation.
#
# Usage:
#   tools/build-monitor.sh <label> <command...>
#
# Examples:
#   tools/build-monitor.sh ext4-1 mvn clean verify
#   INTERVAL=2 tools/build-monitor.sh btrfs-1 mvn clean verify
#
# Output:
#   build-monitor-<label>-<timestamp>/
#     metrics.csv       time-series metrics
#     build.log         workload stdout/stderr
#     time.txt          /usr/bin/time -v output (when available)
#     system-info.txt   environment, filesystem, mount, JVM and Maven info
#     result.txt        label, command, exit code and duration

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
  echo "Usage: $0 <label> <command...>" >&2
  echo "Example: $0 ext4-1 mvn clean verify" >&2
  exit 2
fi
shift

if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 <label> <command...>" >&2
  echo "Example: $0 ext4-1 mvn clean verify" >&2
  exit 2
fi

INTERVAL="${INTERVAL:-5}"
if ! awk -v n="$INTERVAL" 'BEGIN { exit !(n > 0) }'; then
  echo "INTERVAL must be greater than zero: $INTERVAL" >&2
  exit 2
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-build-monitor-${LABEL}-${TIMESTAMP}}"
mkdir -p "$OUTDIR"

METRICS="$OUTDIR/metrics.csv"
BUILD_LOG="$OUTDIR/build.log"
TIME_LOG="$OUTDIR/time.txt"
INFO_LOG="$OUTDIR/system-info.txt"
RESULT_LOG="$OUTDIR/result.txt"

START_EPOCH="$(date +%s)"
START_NS="$(date +%s%N)"

# The filesystem's own block device (for example sdc or loop0).  For a
# loop-backed filesystem we keep the loop device as the target and separately
# record aggregate non-loop I/O as physical/underlying traffic.
MOUNT_SOURCE="$(findmnt -T "$PWD" -n -o SOURCE 2>/dev/null || true)"
TARGET_DEVICE=""
if [[ "$MOUNT_SOURCE" == /dev/* ]]; then
  TARGET_DEVICE="$(basename "${MOUNT_SOURCE%%\[*}")"
fi

read_cpu_freq() {
  local values

  # Prefer cpufreq when the kernel exposes it.  WSL commonly does not, in
  # which case /proc/cpuinfo is only a best-effort signal and must not be
  # treated as proof of host thermal throttling.
  values="$(for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [[ -r "$f" ]] && cat "$f"
  done 2>/dev/null || true)"

  if [[ -n "$values" ]]; then
    awk '
      { mhz=$1/1000; sum+=mhz; if (n==0 || mhz<min) min=mhz; if (n==0 || mhz>max) max=mhz; n++ }
      END { if (n) printf "%.0f %.0f %.0f", sum/n, min, max; else printf "0 0 0" }
    ' <<< "$values"
    return
  fi

  awk '
    /cpu MHz/ {
      mhz=$4; sum+=mhz;
      if (n==0 || mhz<min) min=mhz;
      if (n==0 || mhz>max) max=mhz;
      n++
    }
    END { if (n) printf "%.0f %.0f %.0f", sum/n, min, max; else printf "0 0 0" }
  ' /proc/cpuinfo
}

read_load() {
  awk '{ print $1, $2, $3 }' /proc/loadavg
}

read_memory() {
  awk '
    /MemAvailable:/ { available=$2/1024 }
    /SwapTotal:/    { swap_total=$2/1024 }
    /SwapFree:/     { swap_free=$2/1024 }
    END { printf "%.0f %.0f", available, swap_total-swap_free }
  ' /proc/meminfo
}

read_cpu_stat() {
  awk '
    /^cpu / {
      user=$2+$3
      system=$4+$7+$8
      idle=$5
      iowait=$6
      total=0
      for (i=2; i<=NF; i++) total+=$i
      print user, system, iowait, idle, total
      exit
    }
  ' /proc/stat
}

read_process_pressure() {
  local file="$1"
  local some="0" full="0"

  if [[ -r "$file" ]]; then
    some="$(awk '$1=="some" { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { split($i,a,"="); print a[2] } }' "$file")"
    full="$(awk '$1=="full" { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { split($i,a,"="); print a[2] } }' "$file")"
  fi

  printf '%s %s' "${some:-0}" "${full:-0}"
}

# Return cumulative read/write bytes for one /proc/diskstats device.
read_device_bytes() {
  local device="$1"
  if [[ -z "$device" ]]; then
    printf '0 0'
    return
  fi

  awk -v dev="$device" '
    $3==dev { printf "%.0f %.0f", $6*512, $10*512; found=1; exit }
    END { if (!found) printf "0 0" }
  ' /proc/diskstats
}

# Aggregate non-loop/non-device-mapper block traffic.  In a WSL loop-backed
# Btrfs setup this is useful for observing the underlying virtual disk traffic
# in addition to the logical loop-device traffic.
read_physical_bytes() {
  awk '
    $3 ~ /^(loop|ram|zram|dm-|fd|sr)/ { next }
    { reads += $6*512; writes += $10*512 }
    END { printf "%.0f %.0f", reads, writes }
  ' /proc/diskstats
}

rate_kib_s() {
  local current="$1" previous="$2" delta_ns="$3"
  awk -v c="$current" -v p="$previous" -v n="$delta_ns" '
    BEGIN {
      if (n <= 0 || c < p) { print "0.0"; exit }
      printf "%.1f", ((c-p)/1024)/(n/1000000000)
    }
  '
}

{
  echo "=== monitor ==="
  echo "label=$LABEL"
  echo "interval_seconds=$INTERVAL"
  printf 'command='
  printf '%q ' "$@"
  echo
  echo "working_directory=$PWD"
  echo "mount_source=$MOUNT_SOURCE"
  echo "target_device=${TARGET_DEVICE:-unknown}"
  echo "started_at=$(date --iso-8601=seconds)"

  echo
  echo "=== uname ==="
  uname -a

  echo
  echo "=== WSL ==="
  if [[ -r /proc/sys/kernel/osrelease ]]; then
    cat /proc/sys/kernel/osrelease
  fi
  if command -v wslinfo >/dev/null 2>&1; then
    wslinfo --wsl-version 2>/dev/null || true
  fi

  echo
  echo "=== CPU ==="
  lscpu 2>/dev/null || true

  echo
  echo "=== cpufreq availability ==="
  ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | head -20 || true

  echo
  echo "=== memory ==="
  free -h 2>/dev/null || true

  echo
  echo "=== filesystem ==="
  df -Th "$PWD" 2>/dev/null || true
  findmnt -T "$PWD" 2>/dev/null || true

  echo
  echo "=== loop backing (when applicable) ==="
  if [[ "$MOUNT_SOURCE" == /dev/loop* ]] && command -v losetup >/dev/null 2>&1; then
    losetup "$MOUNT_SOURCE" 2>/dev/null || true
    backing_file="$(losetup -n -O BACK-FILE "$MOUNT_SOURCE" 2>/dev/null || true)"
    if [[ -n "$backing_file" ]]; then
      echo "backing_file=$backing_file"
      findmnt -T "$backing_file" 2>/dev/null || true
    fi
  fi

  echo
  echo "=== block devices ==="
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,ROTA,DISC-GRAN,DISC-MAX 2>/dev/null || true

  echo
  echo "=== Java ==="
  java -version 2>&1 || true

  echo
  echo "=== Maven ==="
  mvn --version 2>&1 || true
} > "$INFO_LOG"

cat > "$METRICS" <<'CSV'
timestamp,elapsed_s,cpu_mhz_avg,cpu_mhz_min,cpu_mhz_max,load1,load5,load15,mem_available_mb,swap_used_mb,cpu_user_pct,cpu_system_pct,cpu_iowait_pct,cpu_idle_pct,target_read_kib_s,target_write_kib_s,physical_read_kib_s,physical_write_kib_s,procs_running,procs_blocked,io_psi_some_avg10,io_psi_full_avg10,mem_psi_some_avg10,mem_psi_full_avg10
CSV

monitor() {
  local prev_user prev_system prev_iowait prev_idle prev_total
  local prev_target_read prev_target_write prev_physical_read prev_physical_write
  local prev_ns

  read -r prev_user prev_system prev_iowait prev_idle prev_total <<< "$(read_cpu_stat)"
  read -r prev_target_read prev_target_write <<< "$(read_device_bytes "$TARGET_DEVICE")"
  read -r prev_physical_read prev_physical_write <<< "$(read_physical_bytes)"
  prev_ns="$(date +%s%N)"

  while true; do
    sleep "$INTERVAL"

    local now_ns now_s elapsed timestamp delta_ns
    local mhz_avg mhz_min mhz_max load1 load5 load15
    local mem_available swap_used user system iowait idle total delta_total
    local cpu_user cpu_system cpu_iowait cpu_idle
    local target_read target_write physical_read physical_write
    local target_read_rate target_write_rate physical_read_rate physical_write_rate
    local running blocked io_some io_full mem_some mem_full

    now_ns="$(date +%s%N)"
    now_s="$(date +%s)"
    elapsed="$((now_s - START_EPOCH))"
    timestamp="$(date --iso-8601=seconds)"
    delta_ns="$((now_ns - prev_ns))"

    read -r mhz_avg mhz_min mhz_max <<< "$(read_cpu_freq)"
    read -r load1 load5 load15 <<< "$(read_load)"
    read -r mem_available swap_used <<< "$(read_memory)"
    read -r user system iowait idle total <<< "$(read_cpu_stat)"
    read -r target_read target_write <<< "$(read_device_bytes "$TARGET_DEVICE")"
    read -r physical_read physical_write <<< "$(read_physical_bytes)"

    delta_total="$((total - prev_total))"
    if (( delta_total > 0 )); then
      cpu_user="$(awk -v a="$((user-prev_user))" -v t="$delta_total" 'BEGIN { printf "%.1f", 100*a/t }')"
      cpu_system="$(awk -v a="$((system-prev_system))" -v t="$delta_total" 'BEGIN { printf "%.1f", 100*a/t }')"
      cpu_iowait="$(awk -v a="$((iowait-prev_iowait))" -v t="$delta_total" 'BEGIN { printf "%.1f", 100*a/t }')"
      cpu_idle="$(awk -v a="$((idle-prev_idle))" -v t="$delta_total" 'BEGIN { printf "%.1f", 100*a/t }')"
    else
      cpu_user="0.0"; cpu_system="0.0"; cpu_iowait="0.0"; cpu_idle="0.0"
    fi

    target_read_rate="$(rate_kib_s "$target_read" "$prev_target_read" "$delta_ns")"
    target_write_rate="$(rate_kib_s "$target_write" "$prev_target_write" "$delta_ns")"
    physical_read_rate="$(rate_kib_s "$physical_read" "$prev_physical_read" "$delta_ns")"
    physical_write_rate="$(rate_kib_s "$physical_write" "$prev_physical_write" "$delta_ns")"

    read -r running blocked <<< "$(awk '
      /^procs_running/ { r=$2 }
      /^procs_blocked/ { b=$2 }
      END { print r+0, b+0 }
    ' /proc/stat)"
    read -r io_some io_full <<< "$(read_process_pressure /proc/pressure/io)"
    read -r mem_some mem_full <<< "$(read_process_pressure /proc/pressure/memory)"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$timestamp" "$elapsed" "$mhz_avg" "$mhz_min" "$mhz_max" \
      "$load1" "$load5" "$load15" "$mem_available" "$swap_used" \
      "$cpu_user" "$cpu_system" "$cpu_iowait" "$cpu_idle" \
      "$target_read_rate" "$target_write_rate" "$physical_read_rate" "$physical_write_rate" \
      "$running" "$blocked" "$io_some" "$io_full" "$mem_some" "$mem_full" \
      >> "$METRICS"

    prev_user="$user"; prev_system="$system"; prev_iowait="$iowait"; prev_idle="$idle"; prev_total="$total"
    prev_target_read="$target_read"; prev_target_write="$target_write"
    prev_physical_read="$physical_read"; prev_physical_write="$physical_write"
    prev_ns="$now_ns"
  done
}

monitor &
MONITOR_PID=$!

cleanup() {
  if [[ -n "${MONITOR_PID:-}" ]]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
  fi
}
trap cleanup EXIT INT TERM

printf 'Monitoring every %ss -> %s\n' "$INTERVAL" "$OUTDIR"
printf 'Running: '
printf '%q ' "$@"
echo

BUILD_START="$(date +%s)"
set +e
if [[ -x /usr/bin/time ]]; then
  /usr/bin/time -v -o "$TIME_LOG" "$@" \
    > >(tee "$BUILD_LOG") \
    2> >(tee -a "$BUILD_LOG" >&2)
  RESULT=$?
else
  : > "$TIME_LOG"
  "$@" \
    > >(tee "$BUILD_LOG") \
    2> >(tee -a "$BUILD_LOG" >&2)
  RESULT=$?
fi
set -e
BUILD_END="$(date +%s)"
DURATION="$((BUILD_END - BUILD_START))"

cleanup
trap - EXIT INT TERM

{
  echo "label=$LABEL"
  printf 'command='
  printf '%q ' "$@"
  echo
  echo "exit_code=$RESULT"
  echo "duration_seconds=$DURATION"
  printf 'duration_hms=%02d:%02d:%02d\n' "$((DURATION/3600))" "$(((DURATION%3600)/60))" "$((DURATION%60))"
  echo "finished_at=$(date --iso-8601=seconds)"
} | tee "$RESULT_LOG"

echo
printf 'Metrics:     %s\n' "$METRICS"
printf 'Build log:   %s\n' "$BUILD_LOG"
printf 'time -v:     %s\n' "$TIME_LOG"
printf 'System info: %s\n' "$INFO_LOG"
printf 'Result:      %s\n' "$RESULT_LOG"

exit "$RESULT"
