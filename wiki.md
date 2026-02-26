# Loom Kernel Architecture Wiki

## Introduction

**iDar-Loom** is the execution engine and preemptive multitasking kernel that powers the advanced features of the iDar Ecosystem. It manages processes, threads, and time slices to ensure no single program can freeze a CC: Tweaked computer.

## Core Concepts

### The Three Pillars of Loom

1. **The Scheduler (`scheduler.lua`)** - The heart of the system. It dispatches events, manages the process queue, and enforces Round-Robin execution.
2. **The Sandbox (`sandbox.lua`)** - The isolated environment where apps run. It wraps standard libraries to safely communicate with the scheduler.
3. **The Core (`core.lua`)** - The process manager responsible for loading code, injecting the sandbox, and starting the kernel loop.

## Execution Guide

### Launching Applications

Applications must be launched through the Core API before starting the scheduler execution. The Core reads the file, compiles it using `load()`, and registers it as a new process.

```lua
local loom = require("iDar.Loom.src.core")

-- Register processes
loom.launch("/apps/my_daemon.lua")
loom.launch("/apps/user_interface.lua")

-- Hand over control to the kernel
loom.execute()

```

## System Configuration

You can tune the kernel's behavior to match your server's tick rate limits. These variables dictate how the Round-Robin scheduler distributes CPU time.

| Parameter           | Default Value | Description                                                                         |
| ------------------- | ------------- | ----------------------------------------------------------------------------------- |
| `base_time`         | `300`         | The standard time limit (in ms) a thread gets before being forced to yield.         |
| `extension_time`    | `100`         | Extra time granted if a thread is forcefully yielded by the kernel.                 |
| `max_time`          | `1000`        | The absolute maximum time slice a thread can accumulate.                            |
| `hook_instructions` | `5000`        | The number of Lua instructions executed before the kernel evaluates the time limit. |

## Sandboxed APIs

To ensure system stability, Loom completely overrides or modifies the following standard CC:T APIs within user applications:

- **`os.sleep(time)`:** Converted into a non-blocking `coroutine.yield("SYSTEM_SLEEP", os.clock() + t)`.
- **`coroutine.create(f)`:** Modified to automatically attach the kernel's time-tracking metadata and the instruction hook to any new child threads spawned by an application.
- **`parallel` (`waitForAll` / `waitForAny`):** Completely rewritten to support the custom thread metadata injected by the sandbox.

## Error Handling

### Process Crashes

Unlike standard CC:T where an unhandled error crashes the entire computer, Loom isolates failures.

- If an application throws a Lua error, the `coroutine.resume` catches it.
- The kernel prints `Error in [process_name]: [error_message]` to the terminal.
- The specific thread is safely removed from the scheduler's queue, allowing all other processes to continue running seamlessly.

### Internal Kernel Events

To prevent CPU-bound processes from starving when there are no user inputs, the kernel generates artificial `"kernel_tick"` events via `os.queueEvent()`. This ensures the scheduler loop continues to iterate and dispatch time slices.
