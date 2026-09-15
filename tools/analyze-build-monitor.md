# Build monitor analysis prompt

Use this prompt after collecting two or more `build-monitor-*` directories with `tools/build-monitor.sh`.

---

I am comparing sustained Maven build performance on WSL, mainly ext4 versus Btrfs. I want to understand not only which run is faster, but **why performance changes during a long workload** and whether an apparent filesystem difference is actually caused by run order, CPU/power limits, I/O pressure, memory pressure, WSL/virtual-disk behavior, or background activity.

I will provide one or more `build-monitor-*` directories or a ZIP containing them. Each run may contain:

- `metrics.csv`: time-series CPU, load, memory, swap, I/O, process blocking and PSI metrics
- `result.txt`: label, command, exit code and wall-clock duration
- `time.txt`: `/usr/bin/time -v` output
- `system-info.txt`: WSL/kernel, CPU, filesystem, mount options, block devices, Java and Maven information
- `build.log`: workload output

## Goal

Analyze the runs adversarially. Do **not** start from the assumption that ext4 is faster, Btrfs is faster, or that thermal throttling is the cause. Separate observations from hypotheses and say what the data can and cannot establish.

The specific behavior I am investigating is that a filesystem may look fast in an early run but become slower after repeated long Maven builds. In previous informal measurements, ext4 sometimes started around 12–13 minutes but later reached roughly 16 minutes, while Btrfs was around 15 minutes. Treat those numbers only as background context; use the supplied run data as the source of truth.

## First: validate the experiment

For every run:

1. Read `result.txt`, `system-info.txt`, `time.txt`, and `metrics.csv`.
2. Confirm the command, filesystem type, mount options, target device, Java/Maven versions, exit code, and duration.
3. Identify differences between runs that could invalidate a direct comparison.
4. Check the time series for missing samples, counter resets, obvious measurement errors, or implausible values.
5. Note whether CPU frequency is coming from Linux cpufreq or only `/proc/cpuinfo`. On WSL, do **not** treat `/proc/cpuinfo` MHz as reliable proof of host thermal throttling.
6. Check whether the Btrfs run is loop-backed. If it is, distinguish:
   - target-device I/O: traffic seen by the filesystem's block device (for example `loop0`)
   - physical/underlying I/O: aggregate non-loop block-device traffic
   Do not assume those two are directly equivalent.

## Analyze each run over time

Do not only compute whole-run averages. Long-build degradation is the main question.

For each run, calculate at least:

- total duration
- first 20%, middle 60%, and last 20% averages
- first half versus second half averages
- trend/slope over elapsed time where meaningful
- median, p90, and maximum for bursty pressure metrics

Use these metrics:

- `cpu_mhz_avg`, `cpu_mhz_min`, `cpu_mhz_max`
- `cpu_user_pct`
- `cpu_system_pct`
- `cpu_iowait_pct`
- `cpu_idle_pct`
- `load1`, `load5`, `load15`
- `target_read_kib_s`, `target_write_kib_s`
- `physical_read_kib_s`, `physical_write_kib_s`
- `mem_available_mb`
- `swap_used_mb`
- `procs_running`
- `procs_blocked`
- `io_psi_some_avg10`, `io_psi_full_avg10`
- `mem_psi_some_avg10`, `mem_psi_full_avg10`

Look specifically for a **change point**: a period after which the run becomes materially more I/O-bound, CPU-limited, memory-pressured, or blocked. If there is a likely change point, report approximately when it occurs and what metrics change with it.

## Compare ext4 and Btrfs

Group runs by filesystem/label and compare them only after accounting for experimental differences.

If there are alternating runs such as:

`ext4-1 -> btrfs-1 -> ext4-2 -> btrfs-2`

explicitly test for **run-order drift**. Ask whether duration increases with run index regardless of filesystem.

If there are enough runs, estimate the filesystem effect separately from the run-order effect. A simple regression or paired comparison is fine; do not pretend a tiny sample is statistically conclusive.

Normalize each run to 0–100% elapsed time and compare the shapes of:

- CPU utilization / idle
- iowait
- I/O PSI
- blocked processes
- target and underlying writes
- available memory and swap

This is important because two 15-minute builds can have very different bottlenecks.

## Test these hypotheses

Rank the following hypotheses from best-supported to least-supported and provide evidence for and against each:

1. **CPU sustained-power / thermal behavior**
   - CPU frequency or CPU throughput falls later in the run.
   - Be conservative on WSL because Linux may not expose trustworthy host temperature or clock telemetry.

2. **Storage saturation / writeback / I/O stalls**
   - increasing `cpu_iowait_pct`
   - increasing `procs_blocked`
   - elevated `io_psi_some_avg10` or `io_psi_full_avg10`
   - changing write throughput with increasing stalls

3. **SSD / virtual-disk sustained-write behavior**
   - underlying physical I/O changes over time while the workload remains heavy
   - evidence consistent with cache exhaustion, GC, or virtual-disk writeback
   - label this as a hypothesis unless host/SSD telemetry proves it

4. **Btrfs compression reducing physical I/O**
   - only claim this if mount options show compression and the measured I/O is consistent with it
   - distinguish logical/target traffic from underlying traffic
   - consider the extra CPU cost of compression

5. **Memory pressure / swapping**
   - falling `mem_available_mb`
   - increasing `swap_used_mb`
   - elevated memory PSI

6. **Background or unrelated I/O**
   - physical I/O substantially exceeds target-device I/O or shows bursts not explained by the build

7. **Filesystem-specific behavior**
   - ext4 and Btrfs show consistently different stall/throughput patterns after controlling for run order and machine state

8. **Measurement noise / insufficient evidence**
   - explicitly choose this when the data does not support a stronger conclusion

## Maven timing

Use `time.txt` to compare wall time, user CPU time, system CPU time, CPU utilization, page faults, context switches, filesystem inputs/outputs, and max RSS where available.

Use `build.log` only to add useful context. Do not infer precise per-Maven-phase timing unless the log actually has timestamps or another reliable timing source.

## Graphs

Create clear graphs when the environment supports it. At minimum produce separate charts for:

1. CPU user/system/iowait/idle over elapsed time
2. CPU frequency over elapsed time (with a warning if WSL telemetry is unreliable)
3. target read/write throughput over elapsed time
4. physical/underlying read/write throughput over elapsed time
5. I/O PSI and blocked processes over elapsed time
6. available memory and swap over elapsed time
7. normalized 0–100% timeline comparing ext4 and Btrfs for the most diagnostic metrics

For noisy series, show both raw or lightly sampled values and a rolling average where useful. Do not smooth away short stall spikes.

## Required final answer

Give me:

### 1. Bottom line
A short answer to:

- Is ext4 actually slower/faster than Btrfs in sustained Maven builds in these samples?
- Does either filesystem degrade more as the machine stays under load?
- How confident are we?

### 2. Run table
One row per run with:

- label
- filesystem
- duration
- user/system CPU time
- average CPU utilization
- average/p90 iowait
- average/p90 I/O PSI
- average target write throughput
- average physical write throughput
- ending swap usage
- notable caveats

### 3. Where performance changes
For each run, identify approximately when behavior changes and which metrics move together.

### 4. Hypothesis ranking
Rank the likely causes with evidence for and against each. Separate facts from inference.

### 5. ext4 vs Btrfs explanation
Explain why the observed difference could occur. If Btrfs compression or loopback changes the I/O path, explain the mechanism carefully rather than just saying "Btrfs is faster".

### 6. Run-order effect
State whether later runs are systematically slower regardless of filesystem. If the sample is too small, say exactly what additional sequence would distinguish it.

### 7. Next experiment
Recommend the **smallest** follow-up experiment that would most reduce uncertainty. Prefer an alternating sequence such as:

`ext4 -> btrfs -> ext4 -> btrfs`

with the same Maven command and similar machine state. Do not suggest a huge benchmark matrix unless the current evidence truly requires it.

### 8. Confidence and limitations
Call out WSL limitations, unavailable host temperature/power telemetry, loop-device accounting issues, sample size, background workload, or any other reason not to over-interpret the result.

## Important analysis rules

- Do not equate high write throughput with good performance; high throughput can coexist with stalls.
- Do not equate low write throughput with a slow filesystem; compression can legitimately reduce bytes written.
- Do not call CPU throttling proven from WSL MHz alone.
- Do not compare only whole-run averages when the question is sustained degradation.
- Do not attribute a difference to the filesystem until run-order drift and system pressure have been considered.
- Prefer measured evidence over generic filesystem folklore.
- If the evidence contradicts my expectation, say so plainly.
