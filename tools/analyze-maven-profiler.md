# Maven profiler analysis and optimization prompt

Use this prompt after collecting Maven profiler output, Maven build logs, `/usr/bin/time -v` output, or system-resource measurements for one or more builds.

---

I want you to analyze Maven build profiling data and determine **what actually dominates wall-clock build time, what is likely causing it, and which changes are most likely to make the build faster**.

Do not merely summarize the profiler output or list generic Maven performance tips. Base recommendations on the supplied measurements, separate facts from hypotheses, and optimize for **total wall-clock time of the build**.

The main command is typically:

```bash
mvn clean verify
```

The machine may also be running a browser, Meet, an IDE, or other background workloads during the build. Therefore, distinguish Maven-internal bottlenecks from machine-level resource contention when the data allows it.

## Goal

Answer these questions:

1. Which modules, lifecycle phases, plugins, and goals consume the most time?
2. Which broad categories dominate the build: compilation, annotation processing, tests, packaging, dependency resolution, code generation, analysis, or something else?
3. Is the observed build primarily CPU-bound, I/O-bound, memory/GC-bound, dependency/network-bound, test-bound, or constrained by serial execution / the reactor critical path?
4. Which changes are most likely to reduce total wall-clock time?
5. Would faster CPU cores, more CPU cores, more RAM, or faster storage materially help?
6. What is the smallest useful experiment to validate each important optimization?

Do not assume that the slowest individual goal is automatically the best optimization target. Prefer changes that shorten the end-to-end build.

## First: validate the input

Before interpreting the results:

1. Identify the exact Maven command and relevant flags.
2. Record Maven version, Java/JDK version, project/module count, and build result if available.
3. Identify whether the build was clean or incremental.
4. Identify whether dependencies were already present in the local repository.
5. Identify whether Maven parallel build (`-T`) or mvnd was used.
6. Identify whether tests or plugins fork additional JVMs/processes.
7. Note any differences between runs that make them unsuitable for direct comparison.
8. If multiple profiler formats or logs are provided, explain which source provides reliable timing for which part of the analysis.

If the profiler output does not expose precise timing for something, say so rather than inferring false precision from ordinary Maven log ordering.

## Rank modules, plugins, phases, and goals

Extract timing information at the finest reliable granularity available.

For each significant item, report:

- module
- lifecycle phase
- plugin
- goal
- total time
- percentage of total wall-clock time when meaningful
- invocation count
- average time per invocation when meaningful
- whether it runs once or repeatedly across modules
- whether it is likely on the build's critical path

Create a table similar to:

| Rank | Module | Plugin / Goal | Time | Share | Invocations | Likely explanation |
| ---: | --- | --- | ---: | ---: | ---: | --- |

Show at least the top 5-10 time consumers when the data supports it.

Also calculate or estimate how much of the measured build is covered by the top 3, top 5, and top 10 entries. This helps distinguish a build dominated by a few hotspots from one whose cost is spread across many small tasks.

## Aggregate into useful categories

Where possible, group measured time into:

- dependency / plugin resolution
- source generation
- resource processing
- Java compilation
- annotation processing
- test compilation
- unit tests
- integration tests
- packaging
- JAR / WAR creation
- shade / assembly / repackaging
- static analysis
- formatting / linting
- documentation generation
- install / local repository operations
- other Maven/plugin overhead

Produce a category table:

| Category | Approx. time | Approx. share | Main contributors |
| --- | ---: | ---: | --- |

Avoid double-counting nested timings. If the profiler representation makes category totals approximate, state that explicitly.

## Identify the bottleneck class

Evaluate each of the following as **High / Medium / Low / Unknown** and explain the evidence.

### CPU bound

Look for evidence such as:

- compiler or CPU-heavy plugins dominate
- high user CPU time
- one or more cores remain saturated
- faster parallelism reduces wall time
- a single module or single-threaded task is the critical path

Distinguish **single-core throughput limitation** from **total-core throughput limitation**.

### I/O bound

Look for evidence such as:

- large amounts of small-file access
- resource copying
- packaging / archive creation
- local Maven repository traffic
- significant iowait / I/O PSI / blocked processes
- CPU has substantial idle time while wall-clock time remains high

Do not declare a goal I/O-bound merely because it reads or writes files.

### Memory / GC bound

Look for:

- heap pressure
- heavy or repeated GC
- swap usage
- memory PSI
- repeated JVM forks
- excessive maximum RSS relative to available memory

### Dependency / network bound

Look for:

- dependency resolution time
- plugin resolution time
- SNAPSHOT metadata checks
- remote repository delays
- repeated downloads or authentication/proxy delays

Separate cold-cache dependency download cost from normal warm local builds.

### Test bound

Inspect Surefire / Failsafe and related tooling for:

- test execution time
- test JVM startup/fork overhead
- serial test execution
- external DB/network/container waits
- uneven test classes
- low CPU utilization despite long test time

### Build graph / serial execution bound

Look for:

- long reactor critical path
- one large module dominating the build
- modules that cannot overlap because of dependencies
- `-T` providing little benefit because the graph is inherently serial
- non-thread-safe plugins that constrain parallel execution

A many-core machine does not help much if the critical path is primarily serial, so call this out explicitly.

## Use `time` data when present

If `/usr/bin/time -v`, shell `time`, or equivalent data is available, use at least:

- elapsed / real time
- user CPU time
- system CPU time
- CPU utilization
- max RSS
- major/minor page faults
- voluntary/involuntary context switches
- filesystem inputs/outputs when available

Interpret `real`, `user`, and `sys` carefully.

Useful clues include:

- `user` near `real` may be consistent with roughly one fully used CPU core
- `user` much larger than `real` indicates substantial CPU parallelism
- `real` much larger than `user + sys` can indicate waiting on I/O, locks, network, sleeps, external services, or child-process accounting differences

Do not treat these as proof by themselves. Account for forked child processes and the semantics of the timing tool.

## Correlate system-resource measurements when present

If CPU, disk, memory, `iostat`, `vmstat`, `pidstat`, PSI, `perf`, or similar measurements are supplied, correlate them with the Maven timing rather than analyzing them separately.

Inspect where available:

- total CPU utilization
- per-core utilization
- iowait
- load average
- disk throughput
- IOPS
- storage latency
- queue depth
- blocked processes
- I/O PSI
- available memory
- swap
- memory PSI
- page faults
- context switches
- CPU frequency / sustained-power behavior

Try to answer questions such as:

> The profiler says compiler:compile is slow. During those intervals, are CPU cores saturated, or is the compiler itself frequently waiting?

and:

> Packaging is slow. Is storage actually saturated, or is compression using CPU while the disk remains underutilized?

If timestamps cannot reliably connect Maven phases with system metrics, say so and recommend a measurement method that can.

## Evaluate Maven-specific optimization candidates

Do not recommend these automatically. For each candidate, explain whether the supplied evidence suggests it will help.

### Maven parallel reactor build

Consider experiments such as:

```bash
mvn -T 1C clean verify
mvn -T 2C clean verify
```

Evaluate:

- reactor dependency graph
- number and size of modules
- critical path
- CPU headroom
- memory headroom
- plugin thread safety
- storage contention

More threads are not automatically better. If additional parallelism would simply increase I/O or memory contention, say so.

### mvnd / daemonized Maven

Assess whether Maven/JVM startup, class loading, plugin initialization, or repeated developer builds are significant enough for mvnd to matter.

If a single 15-minute build is dominated by tests or compilation, do not imply that daemonizing Maven will save minutes unless the data supports it.

### Compiler

Inspect where relevant:

- `maven-compiler-plugin`
- javac
- module-specific compile time
- annotation processors
- generated sources
- compiler forks
- compiler arguments
- repeated compilation

If annotation processors appear expensive, identify them individually when the data allows it.

### Surefire / Failsafe

Inspect:

- `forkCount`
- `reuseForks`
- test parallelism
- number of test JVMs
- startup overhead
- slow test classes
- tests waiting on external dependencies

Separate optimization of test infrastructure from simply deleting or skipping tests. Quality-reducing options should be listed separately, not presented as normal performance tuning.

### Packaging

Inspect plugins such as:

- `maven-jar-plugin`
- `maven-war-plugin`
- `maven-shade-plugin`
- `maven-assembly-plugin`
- Spring Boot repackage

Consider:

- compression CPU cost
- archive I/O
- duplicate archive creation
- repeatedly copying large dependency sets
- unnecessary packaging during local development

### Dependency resolution

Inspect:

- local repository behavior
- SNAPSHOT checks
- repository count
- mirrors/proxies
- plugin resolution
- repeated metadata access
- remote repository latency

Distinguish reproducible warm-build cost from first-run/cold-repository cost.

### Lifecycle scope

For developer builds, CI builds, and release builds separately, evaluate whether always running all the way to `verify` is necessary.

Do not suggest weakening CI or release validation merely to make numbers look better. If a shorter developer feedback command is appropriate, present it as a separate workflow optimization.

## Hardware upgrade assessment

Based on the measurements, rank the likely value of:

1. faster single-core CPU performance
2. more CPU cores
3. more RAM
4. faster SSD/storage

Explain the mechanism.

Examples of useful conclusions:

> Faster single-core CPU is likely to help because one compiler-heavy module dominates the reactor critical path and other cores are frequently idle.

> More cores are unlikely to help much because the reactor is already constrained by a serial module chain.

> Faster storage is unlikely to materially reduce total time because disk latency and iowait stay low while CPU remains saturated.

Avoid generic hardware recommendations without measured support.

## Prioritize improvements

Classify concrete changes as:

- **S - first thing to test**
- **A - likely worthwhile**
- **B - workload-dependent**
- **C - small / cleanup optimization**

For every recommendation include:

- exact change or experiment
- bottleneck it targets
- evidence from this build
- expected effect: Large / Medium / Small, or a justified numeric estimate
- risks / tradeoffs
- how to validate it

Use a table:

| Priority | Change | Bottleneck | Evidence | Expected effect | Risk |
| --- | --- | --- | --- | --- | --- |

Do not manufacture percentage improvements. If there is not enough information to estimate a percentage, use qualitative ranges.

## Required final answer

### 1. Bottom line

Summarize the build in one or two sentences.

Example:

> The build is primarily CPU-limited by Java compilation on the reactor critical path, with tests as the second-largest contributor. Storage does not appear to be saturated.

### 2. Build-time breakdown

Give the best available category breakdown with times and shares.

### 3. Top bottlenecks

List the top 5-10 measured modules/plugins/goals and why they matter.

### 4. Bottleneck classification

Report:

| Type | Rating | Evidence |
| --- | --- | --- |
| CPU | High/Medium/Low/Unknown | ... |
| I/O | High/Medium/Low/Unknown | ... |
| Memory / GC | High/Medium/Low/Unknown | ... |
| Dependency / network | High/Medium/Low/Unknown | ... |
| Tests | High/Medium/Low/Unknown | ... |
| Serial / critical path | High/Medium/Low/Unknown | ... |

### 5. Improvement priorities

Give the S/A/B/C recommendation table.

### 6. The first three experiments to run

Give three concrete experiments, including exact commands or configuration changes where practical.

Prefer experiments that distinguish competing hypotheses, not merely random tuning.

### 7. Hardware recommendation

State whether faster CPU cores, more cores, RAM, or SSD would have the largest expected impact, and why.

### 8. Additional measurements needed

If the existing data cannot answer an important question, say exactly what is missing and provide a practical command or measurement method to collect it.

Examples may include:

```bash
/usr/bin/time -v mvn clean verify
```

```bash
pidstat -dur -p ALL 1
```

```bash
iostat -xz 1
```

or a Maven/plugin-specific profiler when per-goal timing is missing.

Do not request more data unless it would materially change the recommendation.

### 9. Validation plan

Design a before/after benchmark that uses at least 3 runs and preferably 5 runs per configuration.

Report:

- median
- minimum
- maximum
- variation / spread

Control, or explicitly account for:

- warm versus cold filesystem cache
- warm versus cold Maven local repository
- background applications
- JVM/Maven daemon state
- CPU/power state
- run order

For close results, prefer alternating runs such as:

`baseline -> candidate -> baseline -> candidate`

rather than running all baseline measurements first and all candidate measurements second.

## Important analysis rules

- Optimize end-to-end wall-clock time, not isolated plugin timing.
- Do not equate high CPU time with bad performance if parallelism is shortening wall time.
- Do not equate high disk throughput with an I/O bottleneck; inspect wait/latency/PSI as well.
- Do not recommend more Maven threads without considering the reactor critical path and contention.
- Do not claim annotation processing is slow without timing evidence that distinguishes it from javac overall.
- Do not treat first-time dependency downloads as representative of normal warm builds unless that is the target workload.
- Do not claim a hardware upgrade will help unless the measured bottleneck can use it.
- Separate observations, interpretations, and hypotheses.
- Prefer the smallest experiment that can falsify the leading hypothesis.
- If the evidence contradicts my expectation, say so plainly.
