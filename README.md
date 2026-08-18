# RTSyn

RTSyn is the top-level launcher for the RTSyn realtime synthesis stack.

This package does not implement the realtime runtime itself. It selects and runs
one of the client frontends:

- GUI mode, the default, through `rtsyn-gui`.
- CLI mode through `rtsyn-ui` when `--no-gui` is passed.

The GUI and CLI talk to the daemon through the HTTP API. Workspaces are handled
on the client side and translated into API requests; the API, engine, and
runtime do not own workspace concepts.

> [!WARNING]
> It is highly recommended to launch it with a isolated core, adding `isolcpus=domain,managed_irq,3 irqaffinity=0-2 rcu_nocbs=3` for example to the grub launch line.

## Architecture

At runtime the process stack is:

```text
rtsyn
  -> rtsyn-gui                         default frontend
  -> rtsyn-ui CLI                      with --no-gui

rtsyn-ui daemon controller
  -> rtsyn --no-gui daemon run         embedded engine/API daemon process

embedded rtsyn-api <-> SPSC queues <-> embedded rtsyn-engine <-> rtsyn-runtime
```

The HTTP API is intentionally outside the realtime path. The daemon process
links the API and engine libraries into the `rtsyn` executable, creates the SPSC
queues, starts the engine, and serves the HTTP API. The engine owns the runtime,
loads descriptors, executes nodes, consumes command messages from SPSC, and
publishes telemetry.

## Build

## Dependencies

Install these tools before building:

- Xmake.
- Rust toolchain with `cargo` and `rustc`.
- Linux GUI build dependencies:
  - `pkg-config`
  - Fontconfig development headers.

On Debian/Ubuntu:

```bash
sudo apt install pkg-config libfontconfig1-dev
```

On Arch Linux:

```bash
sudo pacman -S pkgconf fontconfig
```

The GUI uses Rust crates that render and export plots with system font support.
If these packages are missing, Cargo can fail while building
`yeslogic-fontconfig-sys`.

Run these commands from this package directory:

```bash
cd rtsyn
```

For local development from the monorepo-style workspace, export the workspace
root so Xmake resolves local RTSyn modules:

```bash
export RTSYN_WORKSPACE=/home/seregio/Desktop/stuff/projects/rtsyn
```

In workspace mode, building the launcher automatically configures and builds
its native sibling repositories incrementally before Cargo links the final
binary. They do not need to be built manually.

Configure and build:

```bash
xmake f -c -y
xmake build rtsyn
```

Select a thread backend with `thread_core`:

```bash
xmake f -c -y --thread_core=posix
xmake f -c -y --thread_core=preempt_rt
xmake f -c -y --thread_core=xenomai
```

The default backend is `posix`.

For `preempt_rt`, grant realtime scheduling permission to the `rtsyn`
executable. The daemon runs from the same binary, so this applies to GUI and CLI
daemon startup. `CAP_IPC_LOCK` is also needed when the preempt-rt backend locks
memory with `mlockall()` and the process does not already have an unlimited
memlock limit:

```bash
sudo setcap cap_sys_nice,cap_ipc_lock=eip build/linux/x86_64/release/rtsyn
```

Reapply this after rebuilding if the binary is replaced.

For short periods, pin the realtime engine thread to a chosen online CPU with
`RTSYN_RT_CPU`. The embedded daemon also reduces the Linux timer slack inherited
by its engine threads to 1 ns by default; override that value with
`RTSYN_RT_TIMER_SLACK_NS` when needed:

```bash
RTSYN_RT_CPU=3 RTSYN_RT_TIMER_SLACK_NS=1 build/linux/x86_64/release/rtsyn
```

For deterministic results, reserve the selected CPU from ordinary workloads and
move unrelated IRQs away from it. CPU affinity alone does not isolate a CPU.

Deadline telemetry compares the engine wake time with its scheduled absolute
deadline. Set the permitted lateness explicitly in nanoseconds; the default is
zero:

```bash
RTSYN_RT_CPU=3 RTSYN_DEADLINE_TOLERANCE_NS=5000 \
  build/linux/x86_64/release/rtsyn
```

`wake_lateness_ns` reports the positive difference from the scheduled deadline,
`deadline_missed` applies the configured tolerance, and `skipped_cycle_count`
counts complete periods of lateness. The older `latency_ns` and `missed_cycle`
fields remain compatibility aliases for wake lateness and deadline missed.

## Run

Open the GUI:

```bash
build/linux/x86_64/release/rtsyn
```

Run CLI commands:

```bash
build/linux/x86_64/release/rtsyn --no-gui <command>
```

Show top-level launcher help:

```bash
build/linux/x86_64/release/rtsyn --help
```

Show CLI help:

```bash
build/linux/x86_64/release/rtsyn --no-gui --help
```

## Daemon

The daemon is a separate `rtsyn --no-gui daemon run` process spawned by the
daemon controller. It does not execute separate `rtsyn-engine` or `rtsyn-api`
binaries; it calls the linked engine/API libraries in-process.

Start it:

```bash
build/linux/x86_64/release/rtsyn --no-gui daemon start
```

Check status:

```bash
build/linux/x86_64/release/rtsyn --no-gui daemon status
```

Stop it:

```bash
build/linux/x86_64/release/rtsyn --no-gui daemon stop
```

The GUI checks for an existing daemon at startup. If one is already running, it
can either use it or restart it for a GUI-owned session.

## Common CLI Commands

Inspect the API:

```bash
build/linux/x86_64/release/rtsyn --no-gui health
```

List runtime nodes and loaded descriptors:

```bash
build/linux/x86_64/release/rtsyn --no-gui nodes
```

Read latest measurements:

```bash
build/linux/x86_64/release/rtsyn --no-gui measurements
```

Set runtime period and RT priority:

```bash
build/linux/x86_64/release/rtsyn --no-gui runtime period 1000000
build/linux/x86_64/release/rtsyn --no-gui runtime priority 50
```

Load and add a plugin:

```bash
build/linux/x86_64/release/rtsyn --no-gui plugin load ../rtsyn-adder/xmake.lua
build/linux/x86_64/release/rtsyn --no-gui plugin add adder
```

Load and add a device:

```bash
build/linux/x86_64/release/rtsyn --no-gui device load ../rtsyn-module-device-comedi/xmake.lua
build/linux/x86_64/release/rtsyn --no-gui device add comedi
```

Start, stop, restart, or remove a runtime node:

```bash
build/linux/x86_64/release/rtsyn --no-gui plugin start 0
build/linux/x86_64/release/rtsyn --no-gui plugin stop 0
build/linux/x86_64/release/rtsyn --no-gui plugin restart 0
build/linux/x86_64/release/rtsyn --no-gui plugin remove 0
```

Add and remove a connection:

```bash
build/linux/x86_64/release/rtsyn --no-gui connection add 0 1 0 2 0
build/linux/x86_64/release/rtsyn --no-gui connection remove 0
```

Subscribe telemetry for ports or states:

```bash
build/linux/x86_64/release/rtsyn --no-gui subscribe ports 0 on 0x7
build/linux/x86_64/release/rtsyn --no-gui subscribe states 0 on 0x1
```

Set a node parameter:

```bash
build/linux/x86_64/release/rtsyn --no-gui param set 0 0 f64 1.0
build/linux/x86_64/release/rtsyn --no-gui param set 0 0 string /dev/comedi0
```

Write selected telemetry to CSV:

```bash
build/linux/x86_64/release/rtsyn --no-gui telemetry csv /tmp/rtsyn.csv adder_left:0 adder_right:1
```

## Workspaces

Workspaces are client-side TOML files. They describe what the client should load
and apply through the API.

Create an empty workspace:

```bash
build/linux/x86_64/release/rtsyn --no-gui workspace new workspace.toml default
```

Apply a workspace:

```bash
build/linux/x86_64/release/rtsyn --no-gui workspace apply workspace.toml
```

## Environment

The daemon controller uses these environment variables:

- `RTSYN_DAEMON_BIN`: path to the `rtsyn` executable used for daemon mode.
- `RTSYN_DAEMON_PID_FILE`: daemon PID file, default `/tmp/rtsyn-daemon.pid`.
- `RTSYN_API_HOST`: host used by the API endpoint.
- `RTSYN_API_PORT`: port used by the API endpoint.

The CLI also accepts a custom API endpoint:

```bash
build/linux/x86_64/release/rtsyn --no-gui --api http://127.0.0.1:17190 nodes
```

## Tests

Run the Rust tests through Xmake:

```bash
xmake test
```

The target delegates to Cargo tests for the Rust package.

## Cleaning

Remove generated build artifacts:

```bash
xmake clean --all
```

Reset cached configuration:

```bash
xmake f -c
```
