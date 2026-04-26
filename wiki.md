# Loom Kernel Architecture Wiki

## Introduction

**iDar-Loom** is the execution engine and preemptive multitasking microkernel that powers the advanced features of the iDar Ecosystem. It manages processes, threads, memory-based IPC, and time slices to ensure no single program can freeze a CC: Tweaked computer, while providing a strictly isolated, POSIX-like environment.

## Core Concepts

### The Five Pillars of Loom

1. **The Scheduler (`scheduler.lua`)** - The heart of the system. It dispatches events, manages the process queue, enforces Round-Robin execution, and handles smart event filtering.
2. **The Sandbox (`sandbox.lua`)** - The isolated environment where apps run. It wraps standard libraries, overrides terminal functions, and injects the `_OS` environment variables.
3. **The Core (`core.lua`)** - The process manager responsible for loading code, injecting the sandbox, and starting the kernel loop.
4. **The Virtual File System (`vfs.lua`)** - The I/O abstraction layer. It manages file descriptors, virtual devices, pipes, and filesystem sandboxing per process.
5. **The Kernel RNG (`krng.lua`)** - The Fortuna/Sha-256/ChaCha20-based cryptographic random number generator that pools entropy from system jitter to feed `/dev/random`.

## Execution Guide

### Launching Applications

Applications must be launched through the Core API before starting the scheduler. The Core reads the file through the VFS, compiles it, registers it as a new process, and assigns it a set of standard file descriptors.

```lua
local loom = require("iDar.opt.Loom.src.core")

-- Register processes
loom.launch("/apps/my_daemon.lua")
loom.launch("/apps/user_interface.lua")

-- Hand over control to the kernel
loom.execute()
```

You can optionally pass an `options` table to inherit file descriptors from a parent process or assign a custom terminal:

```lua
loom.launch("/apps/child.lua", {
    parent_pid = parent_pid,
    fds = { [1] = 4 },   -- Redirect child stdout to parent's FD 4
    term = my_window      -- Assign a custom terminal (e.g. a window object)
})
```

## System Configuration

You can tune the kernel's behavior to match your server's tick rate limits. These variables dictate how the Round-Robin scheduler distributes CPU time.

| Parameter           | Default Value | Description                                                                         |
| ------------------- | ------------- | ----------------------------------------------------------------------------------- |
| `base_time`         | `300`         | The standard time limit (in ms) a thread gets before being forced to yield.         |
| `extension_time`    | `100`         | Extra time granted if a thread is forcefully yielded by the kernel.                 |
| `max_time`          | `1000`        | The absolute maximum time slice a thread can accumulate.                            |
| `hook_instructions` | `5000`        | The number of Lua instructions executed before the kernel evaluates the time limit. |

## Virtual File System (VFS)

The VFS is the I/O abstraction layer of Loom. Instead of letting processes access CC:T's native `fs` API directly, every I/O operation goes through the VFS, which enforces process isolation and tracks open resources.

### File Descriptors & CWD

Every process starts with three standard file descriptors, mirroring Unix conventions, and its own isolated Current Working Directory (CWD).

| FD  | Name   | Type   | Description                                     |
| --- | ------ | ------ | ----------------------------------------------- |
| 0   | stdin  | `term` | Reads input from the TTY daemon.                |
| 1   | stdout | `term` | Writes normal output to the terminal.           |
| 2   | stderr | `term` | Writes error output to the terminal (red text). |

### Inter-Process Communication (Pipes)

Loom supports in-memory data streams via anonymous pipes. Calling `sys.pipe()` returns a read and a write file descriptor. When combined with FD inheritance during `sys.spawn()`, processes can stream data to each other securely without touching the disk.

### Virtual Devices

The VFS exposes three virtual devices that behave like files but are backed by kernel logic:

| Path          | Mode | Description                                  |
| ------------- | ---- | -------------------------------------------- |
| `/dev/null`   | r/w  | Discards all writes. Returns `nil` on read.  |
| `/dev/random` | r    | Returns secure random bytes fed by the KRNG. |
| `/dev/zero`   | r    | Returns `0` on every read.                   |

### Filesystem Sandboxing

Each process is registered with a `root_path` (default: `/iDar`). All file paths are resolved relative to this root. This prevents any process from escaping its designated directory.

### Process Lifecycle

```text
core.launch()
  → vfs.register_process(pid, root_path)   -- Allocate FDs & CWD
  → [process runs]
  → scheduler detects dead process
  → vfs.cleanup_process(pid)               -- Close all open FDs
  → os.queueEvent("process_dead", pid)
```

## Sandboxed APIs

To ensure system stability and process isolation, Loom overrides the following standard CC:T APIs within user applications:

### Modified APIs

- **`os.sleep(time)`:** Converted into a non-blocking coroutine yield tied to a timer event.
- **`coroutine.create(f)`:** Modified to automatically attach the kernel's time-tracking metadata and the instruction hook to any new child threads.
- **`parallel` (`waitForAll` / `waitForAny`):** Completely rewritten to support the custom thread metadata injected by the sandbox.
- **`require(modname)`:** Resolves modules through the VFS instead of the native filesystem.
- **`print(...)`:** Redirected to write through `sys.write(1, ...)`.
- **`read(...)`:** Replaced with a custom, highly advanced terminal reader supporting command history (up/down), tab-autocompletion, and `Ctrl` shortcuts (e.g., `Ctrl+L` to clear, `Ctrl+D` to exit, `Ctrl+A`/`Ctrl+E` for cursor movement).

### Injected Environment (`_OS`)

Every sandboxed process receives an `_OS` global table containing system metadata:

- `_OS.name`: The OS identifier (e.g., "iDar-OS").
- `_OS.Kernel.ver`: The current Loom version.
- `_OS.Packages`: A table of currently installed software packages.

### Removed APIs

- **`fs`:** Set to `nil`. All filesystem access must go through `sys.*` syscalls.
- **`io`:** Set to `nil`. Standard Lua I/O is not available inside the sandbox.

## The `sys` Interface

User applications interact with the kernel through the `sys` global, which exposes the following syscalls:

| Syscall                         | Description                                            |
| ------------------------------- | ------------------------------------------------------ |
| `sys.spawn(path, options, ...)` | Launch a child process.                                |
| `sys.wait(pid)`                 | Block until the target process dies.                   |
| `sys.get_pid()`                 | Returns the current process PID.                       |
| `sys.set_foreground(pid)`       | Request TTY focus for a process.                       |
| `sys.pull_input()`              | Wait for a keyboard event routed to this process.      |
| `sys.open(path, mode)`          | Open a file, returns a file descriptor.                |
| `sys.pipe()`                    | Create an anonymous pipe, returns (fd_read, fd_write). |
| `sys.read(fd)`                  | Read all content from a file descriptor.               |
| `sys.read_line(fd)`             | Read one line from a file descriptor.                  |
| `sys.write(fd, data)`           | Write data to a file descriptor.                       |
| `sys.close(fd)`                 | Close a file descriptor.                               |
| `sys.get_cwd()`                 | Get the process's current working directory.           |
| `sys.set_cwd(path)`             | Set the process's current working directory.           |
| `sys.exists(path)`              | Check if a path exists.                                |
| `sys.is_dir(path)`              | Check if a path is a directory.                        |
| `sys.list(path)`                | List directory contents.                               |
| `sys.mkdir(path)`               | Create a directory.                                    |
| `sys.move(init, dest)`          | Move or rename a file/directory.                       |
| `sys.delete(path)`              | Delete a file or directory.                            |
| `sys.get_capacity(path)`        | Get the storage capacity of the drive.                 |
| `sys.get_free_space(path)`      | Get the free storage space of the drive.               |
| `sys.lines(fd)`                 | Returns an iterator that reads one line at a time.     |
| `sys.dofile(path)`              | Execute a Lua file using the VFS sandboxed paths.      |
| `sys.combine(...)`              | Path utility, wraps `fs.combine`.                      |

## Advanced Kernel Features

### Process Crashes & Isolation

Unlike standard CC:T where an unhandled error crashes the entire computer, Loom isolates failures.

- If an application throws a Lua error, the `coroutine.resume` catches it.
- The kernel prints `Error in [process_name]: [error_message]` to the terminal.
- The specific thread is safely removed from the scheduler's queue, allowing all other processes to continue running seamlessly.

### Smart Event Filtering

Loom heavily optimizes CPU usage by natively tracking what event a thread is waiting for. If a thread calls `coroutine.yield("timer")`, the kernel saves `"timer"` as its active filter. The scheduler will **not** waste CPU cycles attempting to resume this thread unless the incoming event is a `"timer"` (or a system `"terminate"` signal).

### Entropy Gathering (KRNG)

To supply `/dev/random` with cryptographically secure bytes, the kernel constantly measures the execution time jitter between `os.pullEventRaw()` calls. This unpredictable hardware/server delay is fed into a Fortuna-style entropy pool and hashed via SHA-256 to provide true randomness even inside Minecraft.
