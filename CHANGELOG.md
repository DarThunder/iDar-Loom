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

### v3.0.0

### Added

#### Core Kernel & Scheduler

- **Completely Fair Scheduler (CFS):** Replaced the legacy Round-Robin scheduler with a highly advanced CFS. Thread execution is now determined by a `vruntime` (virtual runtime) variable tracked inside a binary Min-Heap (`binary_heap.lua`), ensuring perfectly fair CPU distribution.
- **Priority Weighting:** Introduced the `superrr` parameter (niceness) for processes. Threads with higher `superrr` values accumulate `vruntime` slower, granting them more physical CPU time relative to standard background tasks.

#### Security & Permissions

- **UID-based Sandboxing:** The VFS now enforces strict read/write permissions. Every process operates under a User ID (`uid`), and file access is evaluated against rules defined in `/etc/permissions.conf`.
- **Sudo & Authentication:** Added the `sys.sudo(username, password, ...)` syscall. It securely hashes the input using SHA-256 and authenticates against `/etc/shadow` and `/etc/group`. If successful (and the user is in the `wheel` group), it spawns a child process with `UID 0` (root privileges).

#### Networking & Sockets

- **Socket Abstraction:** Modems are now natively treated as network interface file descriptors (`FD_TYPE.SOCKET`).
- **Network Syscalls:** Introduced a complete networking stack inside the `sys` API: `sys.socket()`, `sys.bind()`, `sys.connect()`, `sys.send()`, and `sys.recv()`.
- **Kernel-level Packet Routing:** Physical `modem_message` events are no longer broadcasted blindly to all processes. The kernel natively intercepts them and routes the payload exclusively to the file descriptor buffer of the process bound to the receiving port.

#### Cryptography & Advanced VFS

- **Native Crypto Syscalls:** Exposed the kernel's internal cryptographic capabilities to userspace. Applications can now natively call `sys.encrypt()` (ChaCha20 stream cipher) and `sys.sha256()` without needing external Lua libraries.
- **Shared Library Caching:** Optimized the sandboxed `require()` function to maintain a `shared_lib_cache` in memory, drastically reducing VFS disk reads when multiple processes require the same standard libraries.

### Changed

- **Coroutine Hook Evolution:** The `debug.sethook` implementation was refactored to support the new `vruntime` calculation and forced-yield logic of the CFS Min-Heap.
- **Global Environment (`_OS`):** Kernel version in the injected `_OS` table bumped to reflect the Alpha 3 microkernel architecture.

### v4.0.0

### Added

#### Core Kernel & Syscalls

- **POSIX Software Interrupts:** Deprecated the legacy `sys` API table injection in favor of a true software-interrupt architecture. Userspace applications now interact with the kernel by yielding a sequential table with hexadecimal syscall IDs (e.g., `0x00` for read, `0x01` for write, `0x3B` for execve).
- **Syscall Dispatcher:** Introduced `ksyscalls.lua` to securely route hexadecimal requests to Ring 0 functions.
- **POSIX Error Codes:** The kernel now maps failures to standard C `errno` codes, returning negative values (e.g., `-errno.EBADF`, `-errno.ENOENT`, `-errno.EACCES`) on failed syscalls instead of generic boolean flags.
- **Userland C-Libraries:** Introduced standard wrapper libraries (`unistd` and `stdio` in `Clib`) to abstract the raw CISS hexadecimal yields from end-user programs.

#### Virtual Terminals (TTY) & ANSI

- **Multi-Console Multiplexing:** Implemented a kernel-level TTY driver (`tty.lua`) that handles up to 6 virtual consoles simultaneously.
- **Hardware Hot-Swapping:** Users can instantly switch the active foreground console and keyboard input routing using `Ctrl + 1` through `Ctrl + 6`.
- **Native ANSI Support:** The TTY driver features a built-in parser for ANSI escape sequences, managing text colors, background colors, cursor positioning, and line clearing directly at the kernel level.

#### Virtual File System (VFS)

- **Synthetic Filesystems (`/proc` and `/sys`):** The VFS now dynamically generates system and hardware status files. Added `/proc/cpuinfo` (virtual CPU stats and BogoMIPS), `/proc/meminfo` (simulated RAM usage), `/proc/uptime`, and `/proc/version`.
- **Network Hardware Addresses:** Added `/sys/class/net/modem0/address` to expose the physical computer ID as a standard MAC address.
- **SUID Execution:** Process creation (`execve`) now evaluates the Set-User-ID (SUID) bit via file attributes, seamlessly assigning the effective UID of the file owner upon execution for secure privilege escalation.

### Changed

- **Process Management:** Completely removed string-based task commands (like `"fork"`, `"wait"`, `"get_pid"`). All process lifecycle management is now strictly handled through the `0x01` syscall bus using their POSIX hex IDs (`0x3B execve`, `0x3D wait`, `0x27 getpid`).
- **Scheduler Tuning:** Refactored scheduler configuration in `boot/config.lua`. Replaced static base times with `target_latency` and `min_granularity` variables for a more mathematically accurate Completely Fair Scheduler (CFS) time-slicing equation.
