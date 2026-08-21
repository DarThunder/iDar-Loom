# Loom Kernel Architecture Wiki

## Introduction

**iDar-Loom** is the execution engine and preemptive multitasking CISS monolithic kernel that powers the advanced features of the iDar Ecosystem. It manages processes, threads, memory-based IPC, network sockets, user permissions, virtual terminals (TTY), and CPU time slices. By utilizing a Completely Fair Scheduler (CFS) and strict Ring 0 / Ring 3 isolation, it ensures no single program can freeze a CC: Tweaked computer while providing a highly secure and robust execution environment[cite: 5].

## Core Concepts

### The Five Pillars of Loom

1. **The CFS Scheduler (`scheduler.lua`)** - The heart of the system. It abandons simple Round-Robin in favor of a Completely Fair Scheduler using binary Min-Heaps and `vruntime`[cite: 5]. It dispatches hardware events asynchronously, enforces priority weighting (`superrr`), and handles process preemption.
2. **The Sandbox (`sandbox.lua`)** - The isolated userspace (Ring 3) where apps run. It wraps standard libraries, intercepts malicious metatable modifications, and enforces the software-interrupt (`syscall`) boundary.
3. **The Syscall Dispatcher (`ksyscalls.lua`)** - The CISS interface. It receives hexadecimal interrupt signals from userspace and maps them to Ring 0 kernel functions, returning standard C `errno` codes on failure.
4. **The Virtual File System (`vfs.lua`)** - The I/O abstraction layer. It manages file descriptors, virtual devices (`/dev`), synthetic filesystems (`/proc`, `/sys`), pipes, network sockets, and enforces UID-based filesystem sandboxing per process.
5. **The Kernel RNG & Crypto (`krng.lua`)** - The Fortuna/Sha-256/ChaCha20-based cryptographic module. It pools entropy from system jitter to feed `/dev/random` and provides internal crypto operations.

## Execution Guide

### Launching the Initial Process (init)

Loom is a kernel, not an OS. To start the system, you must launch an initial userspace process (like a shell or init daemon) through the Core API, which then takes over launching other programs.

```lua
local core = require("iDar.boot.Loom.core")

-- Register the initial process
core.launch("/bin/shell.lua")

-- Hand over control to the kernel (Blocking)
core.execute()

```

## System Configuration

You can tune the kernel's scheduler behavior in `boot/config.lua` to match your server's tick rate limits.

| Parameter           | Default Value | Description                                                                         |
| ------------------- | ------------- | ----------------------------------------------------------------------------------- |
| `target_latency`    | `24`          | The targeted maximum latency (in ms) before every ready process gets a turn.        |
| `min_granularity`   | `2`           | The minimum time slice (in ms) a process is guaranteed to run.                      |
| `hook_instructions` | `5000`        | The number of Lua instructions executed before the kernel evaluates the time limit. |

## Virtual File System (VFS) & Security

All I/O operations and hardware interactions are forced through the VFS to enforce process isolation and UID permissions.

### File Descriptors & CWD

Every process starts with three standard file descriptors and its own isolated Current Working Directory (CWD).

| FD  | Name   | Type   | Description                                    |
| --- | ------ | ------ | ---------------------------------------------- |
| 0   | stdin  | `term` | Reads input from the active TTY console.       |
| 1   | stdout | `term` | Writes normal output to the active console.    |
| 2   | stderr | `term` | Writes error output to the console (red text). |

### Synthetic and Virtual Filesystems

Loom dynamically generates file contents for specific paths to expose hardware and system states:

- **`/proc/` (Process Information Pseudo-file System)**:
- `/proc/cpuinfo`: Displays virtual CPU specs (BogoMIPS, flags).
- `/proc/meminfo`: Displays simulated RAM usage.
- `/proc/uptime`: Kernel uptime.
- `/proc/version`: Current Kernel version string.

- **`/sys/` (System pseudo-filesystem)**:
- Exposes physical hardware addresses (e.g., `/sys/class/net/modem0/address`).

- **`/dev/` (Device nodes)**:
- `/dev/null`: Discards all writes. Returns `nil` on read.
- `/dev/random`: Returns secure random bytes fed by the KRNG.
- `/dev/zero`: Returns `0` on every read.

### Inter-Process Communication (Pipes & Sockets)

- **Pipes:** In-memory data streams via anonymous pipes (`0x16`). Perfect for streaming data between parent and child processes securely (e.g., `echo "hello" | cat`).

- **Sockets:** Loom abstracts modems into standard file descriptors. Calling `socket` (`0x29`) creates a network interface that can be bound to local ports or connected to remote computers, allowing `read()` and `write()` to handle network packets transparently.

## The CISS Syscall Interface

In Loom 4.0.0, userspace applications **do not** interact with the kernel through global Lua tables. Instead, they trigger software interrupts using `coroutine.yield()` with a specific data structure.

_Format: `coroutine.yield({0x01, SYSCALL_ID, arg1, arg2, ...})_`

If a syscall fails, it returns a negative `errno` code (e.g., `-errno.EBADF`, `-errno.ENOENT`).

### Standard Common Library Wrappers (Userland)

Because making raw syscalls is tedious, userspace applications should use C-style wrappers provided in `/Clib/` (like `unistd` and `stdio`).

### Core Syscall Reference

| ID      | CISS Name    | Arguments                | Description                                              |
| ------- | ------------ | ------------------------ | -------------------------------------------------------- |
| `0x00`  | `read`       | `(fd)`                   | Reads data from a file descriptor.                       |
| `0x01`  | `write`      | `(fd, data)`             | Writes data to a file descriptor.                        |
| `0x02`  | `open`       | `(path, mode)`           | Opens a file, returns a file descriptor.                 |
| `0x03`  | `close`      | `(fd)`                   | Closes a file descriptor.                                |
| `0x16`  | `pipe`       | `()`                     | Creates an anonymous pipe, returns `(fd_read, fd_write)` |
| `0x27`  | `getpid`     | `()`                     | Returns the current process PID.                         |
| `0x3B`  | `execve`     | `(path, {options}, ...)` | Clones FDs, handles SUID, and spawns a child process.    |
| `0x3C`  | `exit`       | `(exit_code)`            | Terminates the current process.                          |
| `0x3D`  | `wait`       | `(pid)`                  | Blocks until the target process dies.                    |
| `0x3E`  | `kill`       | `(pid)`                  | Terminates a target process (requires UID 0 or owner).   |
| `0x50`  | `chdir`      | `(path)`                 | Changes the Current Working Directory.                   |
| `0x66`  | `getuid`     | `()`                     | Returns the effective and real UID.                      |
| `0x201` | `assign_tty` | `(pid, console_id)`      | Assigns a process to one of the 6 virtual consoles.      |

_(Note: Network sockets use `0x29 socket`, `0x31 bind`, `0x2A connect`, `0x2C send`)_

## Advanced Kernel Features

### The CFS Scheduler (Completely Fair Scheduler)

Loom uses a highly advanced Min-Heap priority queue to schedule threads. Instead of assigning equal time to all threads, it tracks a thread's `vruntime` (virtual runtime).

- Threads that have consumed less CPU time are kept at the top of the Min-Heap.

- A thread's `superrr` parameter acts as a weight modifier. Threads with higher priority accumulate `vruntime` slower, granting them more physical CPU time relative to lower-priority threads.

### Virtual Terminals (TTY)

Loom features a kernel-level TTY driver that abstracts the physical screen into 6 independent virtual consoles.

- Users can switch between active sessions using `Ctrl + 1` through `Ctrl + 6`.

- The kernel natively parses ANSI escape sequences (e.g., `\27[31m` for red text), handling cursor positioning, colors, and line clearing without requiring userspace Lua APIs.

### Entropy Gathering (KRNG)

To supply `/dev/random` with cryptographically secure bytes, the kernel constantly measures the execution time jitter between hardware ticks and unpredictable network events. This delay is fed into a Fortuna-style entropy pool and hashed via SHA-256 to provide true randomness even inside a Minecraft simulation environment.
