# Loom Kernel Architecture Wiki

## Introduction

**iDar-Loom** is the execution engine and preemptive multitasking POSIX-like microkernel that powers the advanced features of the iDar Ecosystem. It manages processes, threads, memory-based IPC, network sockets, user permissions, and time slices. By utilizing a Completely Fair Scheduler (CFS) and strict Ring 0 / Ring 3 isolation, it ensures no single program can freeze a CC: Tweaked computer while providing a highly secure and robust execution environment.

## Core Concepts

### The Five Pillars of Loom

1. **The CFS Scheduler (`scheduler.lua`)** - The heart of the system. It abandons simple Round-Robin in favor of a Completely Fair Scheduler using binary Min-Heaps and `vruntime`. It dispatches events, manages the process queue, enforces priority weighting (`superrr`), and handles smart event filtering.
2. **The Sandbox (`sandbox.lua`)** - The isolated userspace (Ring 3) where apps run. It wraps standard libraries, overrides terminal functions, enforces the system call (`sys`) boundary, and injects the `_OS` environment variables.
3. **The Core (`core.lua`)** - The process manager responsible for loading code, injecting the sandbox, and starting the kernel loop.
4. **The Virtual File System (`vfs.lua`)** - The I/O abstraction layer. It manages file descriptors, virtual devices, pipes, network sockets, and enforces UID-based filesystem sandboxing per process.
5. **The Kernel RNG & Crypto (`krng.lua`)** - The Fortuna/Sha-256/ChaCha20-based cryptographic module. It pools entropy from system jitter to feed `/dev/random` and provides native crypto syscalls to userspace.

## Execution Guide

### Launching Applications

Applications must be launched through the Core API before starting the scheduler. The Core reads the file through the VFS, compiles it, registers it as a new process, and assigns it a set of standard file descriptors and a UID.

```lua
local loom = require("iDar.opt.Loom.src.core")

-- Register processes
loom.launch("/apps/my_daemon.lua")
loom.launch("/apps/user_interface.lua")

-- Hand over control to the kernel
loom.execute()

```

You can pass an `options` table to inherit file descriptors, set process priority (niceness), or assign a custom terminal:

```lua
loom.launch("/apps/child.lua", {
    parent_pid = parent_pid,
    superrr = 2,          -- Increase priority weight for the CFS scheduler
    uid = 1000,           -- Run as a specific user ID
    fds = { [1] = 4 },    -- Redirect child stdout to parent's FD 4
    term = my_window      -- Assign a custom terminal (e.g. a window object)
})

```

## System Configuration

You can tune the kernel's time-slicing behavior to match your server's tick rate limits.

| Parameter           | Default Value | Description                                                                         |
| ------------------- | ------------- | ----------------------------------------------------------------------------------- |
| `base_time`         | `300`         | The standard time limit (in ms) a thread gets before being forced to yield.         |
| `extension_time`    | `100`         | Extra time granted if a thread is forcefully yielded by the kernel.                 |
| `max_time`          | `1000`        | The absolute maximum time slice a thread can accumulate.                            |
| `hook_instructions` | `5000`        | The number of Lua instructions executed before the kernel evaluates the time limit. |

## Virtual File System (VFS) & Security

The VFS is the I/O and Security abstraction layer of Loom. All I/O operations and hardware interactions are forced through the VFS to enforce process isolation and UID permissions.

### File Descriptors & CWD

Every process starts with three standard file descriptors, mirroring Unix conventions, and its own isolated Current Working Directory (CWD).

| FD  | Name   | Type   | Description                                     |
| --- | ------ | ------ | ----------------------------------------------- |
| 0   | stdin  | `term` | Reads input from the TTY daemon.                |
| 1   | stdout | `term` | Writes normal output to the terminal.           |
| 2   | stderr | `term` | Writes error output to the terminal (red text). |

### Security & UID Permissions

Loom implements a strict permission system. Every VFS operation checks the process's `uid` against `/etc/permissions.conf`.

- **UID 0 (root)** has unrestricted access to the virtual filesystem.
- Processes can temporarily elevate privileges using `sys.sudo()`, which validates against SHA-256 hashed passwords in `/etc/shadow` and checks for `wheel` group membership in `/etc/group`.

### Inter-Process Communication (Pipes & Sockets)

- **Pipes:** In-memory data streams via anonymous pipes (`sys.pipe()`). Perfect for streaming data between parent and child processes securely.
- **Sockets:** Loom abstracts modems into standard file descriptors. Calling `sys.socket()` creates a network interface that can be bound to local ports or connected to remote computers, allowing `sys.read()` and `sys.write()` to handle network packets transparently.

### Virtual Devices

The VFS exposes virtual devices backed by kernel logic:

| Path          | Mode | Description                                  |
| ------------- | ---- | -------------------------------------------- |
| `/dev/null`   | r/w  | Discards all writes. Returns `nil` on read.  |
| `/dev/random` | r    | Returns secure random bytes fed by the KRNG. |
| `/dev/zero`   | r    | Returns `0` on every read.                   |

## Sandboxed APIs

To ensure system stability, Loom overrides the following standard CC:T APIs within user applications:

### Modified APIs

- **`os.sleep(time)`:** Converted into a non-blocking coroutine yield tied to a timer event.
- **`coroutine.create(f)`:** Modified to automatically attach the kernel's `vruntime` metadata and the instruction hook to child threads.
- **`parallel` (`waitForAll` / `waitForAny`):** Rewritten to support the custom CFS thread metadata.
- **`require(modname)`:** Resolves modules through the VFS. Supports dynamic shared library caching.
- **`print(...)`:** Redirected to `sys.write(1, ...)`.
- **`read(...)`:** Replaced with an advanced terminal reader supporting command history, tab-autocompletion, and `Ctrl` shortcuts (`Ctrl+L`, `Ctrl+D`, `Ctrl+A`, `Ctrl+E`, `Ctrl+K`).

### Injected Environment (`_OS`)

Every sandboxed process receives an `_OS` global table:

- `_OS.name`: OS identifier (e.g., "iDar-OS").
- `_OS.Kernel.ver`: Current Loom version.
- `_OS.Packages`: Currently installed software packages via `iDar-Pacman`.

### Removed APIs

- **`fs` & `io`:** Set to `nil`. Standard filesystem/IO access must go through `sys.*` syscalls.

## The `sys` Interface

User applications interact with the kernel strictly through the `sys` global table:

### Process & Security

| Syscall                           | Description                                       |
| --------------------------------- | ------------------------------------------------- |
| `sys.spawn(path, opts, ...)`      | Launch a child process.                           |
| `sys.wait(pid)`                   | Block until the target process dies.              |
| `sys.get_pid()`                   | Returns the current process PID.                  |
| `sys.set_foreground(pid)`         | Request TTY focus for a process.                  |
| `sys.pull_input()`                | Wait for a keyboard event routed to this process. |
| `sys.sudo(user, pass, app, opts)` | Authenticate and spawn a process as UID 0 (root). |
| `sys.getuid()`                    | Returns the current User ID.                      |

### VFS & I/O

| Syscall                | Description                                              |
| ---------------------- | -------------------------------------------------------- |
| `sys.open(path, mode)` | Open a file, returns a file descriptor.                  |
| `sys.pipe()`           | Create an anonymous pipe, returns `(fd_read, fd_write)`. |
| `sys.read(fd)`         | Read all content from a file descriptor.                 |
| `sys.read_line(fd)`    | Read one line from a file descriptor.                    |
| `sys.write(fd, data)`  | Write data to a file descriptor.                         |
| `sys.close(fd)`        | Close a file descriptor.                                 |

### Network (Sockets)

| Syscall                     | Description                                     |
| --------------------------- | ----------------------------------------------- |
| `sys.socket()`              | Creates a network socket file descriptor.       |
| `sys.bind(fd, port)`        | Binds a socket to a local port.                 |
| `sys.connect(fd, id, port)` | Establishes connection to a remote computer ID. |
| `sys.send(fd, data)`        | Send data packet through an established socket. |
| `sys.recv(fd)`              | Receive data packet (Alias for `sys.read`).     |
| `sys.get_port(fd)`          | Returns the local port bound to the socket.     |

### Cryptography

| Syscall                        | Description                                    |
| ------------------------------ | ---------------------------------------------- |
| `sys.encrypt(msg, key, nonce)` | Native ChaCha20 stream cipher encryption.      |
| `sys.sha256(data)`             | Native SHA-256 hashing. Returns binary digest. |

### Filesystem Manipulation

| Syscall                                               | Description                             |
| ----------------------------------------------------- | --------------------------------------- |
| `sys.get_cwd()` / `sys.set_cwd(path)`                 | Manage the process's working directory. |
| `sys.exists(path)` / `sys.is_dir(path)`               | Check path status.                      |
| `sys.list(path)`                                      | List directory contents.                |
| `sys.mkdir(path)`                                     | Create a directory.                     |
| `sys.move(init, dest)`                                | Move or rename a file/directory.        |
| `sys.delete(path)`                                    | Delete a file or directory.             |
| `sys.get_capacity(path)` / `sys.get_free_space(path)` | Drive storage metrics.                  |

## Advanced Kernel Features

### The CFS Scheduler (Completely Fair Scheduler)

Loom uses a highly advanced Min-Heap priority queue to schedule threads. Instead of assigning equal time to all threads, it tracks a thread's `vruntime` (virtual runtime).

- Threads that have consumed less CPU time are kept at the top of the Min-Heap.
- A thread's `superrr` parameter acts as a weight modifier. Threads with higher priority accumulate `vruntime` slower, granting them more physical CPU time relative to lower-priority threads.

### Smart Event Filtering & Packet Routing

Loom heavily optimizes CPU usage by natively tracking what event a thread is waiting for.

- If a thread calls `coroutine.yield("timer")`, the kernel saves `"timer"` as its active filter. It will **not** wake the thread for any other event.
- Network events (`modem_message`) are intercepted natively by the kernel and routed exclusively to the file descriptor buffers of processes bound to the corresponding port, preventing event flooding across the entire system.

### Entropy Gathering (KRNG)

To supply `/dev/random` with cryptographically secure bytes, the kernel constantly measures the execution time jitter between `os.pullEventRaw()` calls, hardware ticks, and unpredictable network events. This delay is fed into a Fortuna-style entropy pool and hashed via SHA-256 to provide true randomness even inside a Minecraft simulation environment.
