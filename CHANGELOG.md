# Changelog

All notable changes to the **iDar-Loom** project will be documented in this file. (I hope lol)

## Alpha

### v1.0.0

### Added

#### Core Kernel & Scheduler

- **Preemptive Multitasking:** Implemented a Round-Robin scheduler that forces threads to yield using `debug.sethook()` and instruction counting.
- **Time Slicing:** Added a dynamic execution time manager that tracks how long a thread has been running and forces a yield if it exceeds the allocated slice.
- **Event Dispatcher:** Built a robust event handler that catches standard `os.pullEventRaw()` data and feeds it only to the threads waiting for those specific events.
- **Artificial Ticks:** Introduced the internal `"kernel_tick"` event to keep CPU-bound processes running smoothly when the CC:T event queue is empty.
- **Crash Isolation:** The scheduler now catches Lua errors within individual threads, terminating the failing process without bringing down the entire kernel.

#### Sandboxing & API Overrides

- **Isolated Environment:** Created `sandbox.lua` to run loaded applications in a controlled global environment.
- **Non-blocking `sleep`:** Rewrote the `sleep()` function to yield with a `"SYSTEM_SLEEP"` signal instead of halting the system.
- **Custom `coroutine` API:** Overrode `coroutine.create` to automatically inject kernel tracking metadata and instruction hooks into any child thread spawned by an application.
- **Custom `parallel` API:** Re-engineered `parallel.waitForAll` and `parallel.waitForAny` to properly evaluate the execution status of sandboxed kernel threads.

#### Process Management

- **Launcher:** Added `core.launch()` to load scripts from the filesystem, compile them safely via `load()`, and register them into the process queue.
- **Configuration API:** Exposed setter functions (`setBaseTime`, `setExtensionTime`, `setMaxTime`) to allow users to tweak the scheduler's performance parameters before execution.

#### Testing Suite

- Added `cpu_stress.lua` for heavy mathematical workload testing.
- Added `sleep_spam.lua` to test timer resolution and wake-up accuracy.
- Added `mixed_load.lua` to benchmark the scheduler's ability to juggle CPU, I/O, and Sleep operations concurrently.
- Added `parallel_test.lua` to verify the stability of the rewritten `parallel` API within the sandbox.

### v1.0.1

Bug fixes and performance improvements

### v2.0.0

### Added

#### Core Kernel & Scheduler

- **Smart Event Filtering:** The scheduler now natively tracks the specific event a thread yielded for (`active_meta.filter`), waking it up only when that exact event (or a terminate signal) occurs, massively reducing wasted CPU cycles.
- **Kernel RNG (KRNG):** Implemented a cryptographically secure random number generator based on the Fortuna and ChaCha20 algorithms. It pools entropy from system event jitter to feed `/dev/random` with true randomness.

#### Virtual File System (VFS) & IPC

- **Inter-Process Communication:** Added support for anonymous pipes (`sys.pipe()`), allowing processes to stream data to each other entirely in memory.
- **CWD Isolation:** Each process now manages its own isolated Current Working Directory (`sys.set_cwd`, `sys.get_cwd`).
- **File Descriptor Inheritance:** Child processes can now inherit specific file descriptors from their parents when spawned via `sys.spawn`, enabling output redirection.
- **Expanded Syscalls:** Added comprehensive filesystem syscalls including `mkdir`, `move`, `delete`, `get_capacity`, `get_free_space`, and internal execution via `dofile`.

#### Sandboxing & Environment

- **Advanced Terminal Input:** The standard `read()` function has been completely rewritten inside the sandbox. It now natively supports command history, tab-autocompletion, cursor movement, and `Ctrl` shortcuts (e.g., `Ctrl+L` to clear, `Ctrl+D` to exit).
- **Environment Metadata (`_OS`):** The kernel now automatically injects a global `_OS` table into applications, exposing the OS name, kernel version, and dynamically loading installed packages from `iDar/var/local.lua`.
- **Foreground Control:** Introduced `sys.set_foreground` and `sys.pull_input` to securely route raw terminal keyboard/character events only to the focused process.

### Changed

- Refactored process registration to handle the new advanced VFS structures and process-specific file descriptors.
- Removed legacy "Artificial Ticks" logic (`kernel_tick`), replacing it with optimized event yielding that handles CPU needs dynamically.
