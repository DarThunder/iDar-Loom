# Changelog

All notable changes to the **iDar-Loom** project will be documented in this file.

## Alpha

### V1.0.0

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
