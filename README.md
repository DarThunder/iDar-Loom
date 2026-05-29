# iDar-Loom

![State: Alpha 3](https://img.shields.io/badge/State-Alpha_3-orange)

**The preemptive multitasking microkernel, CFS scheduler, and execution engine for ComputerCraft: Tweaked.**

> _"Too long without yielding? Not on my watch."_

**iDar-Loom** has evolved far beyond a simple task scheduler. It is a robust, lightweight **POSIX-like microkernel** built to solve the most annoying problems in CC: Tweaked: the dreaded `"Too long without yielding"` error, lack of process isolation, non-existent security, and poor inter-process communication.

Loom brings Linux-grade OS concepts to a Minecraft mod: **true preemptive multitasking** using a Completely Fair Scheduler (CFS) with Min-Heaps, a sandboxed environment with Ring 0 / Ring 3 isolation, a real UID-based permission system, network sockets, and a powerful system call API. Multiple complex applications can now run concurrently, pipe data to each other, communicate over the network, and manage their own environments without ever freezing the in-game computer.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [Basic Implementation](#basic-implementation)
  - [Configuration](#configuration)
- [The `sys` API](#the-sys-api)
- [How it Works](#how-it-works)
- [FAQ](#faq)
- [License](#license)

## Features

- **Preemptive CFS Multitasking**: Automatically intercepts and yields CPU-hogging processes using `debug.sethook()`. Loom abandons simple round-robin for a **Completely Fair Scheduler (CFS)** using binary Min-Heaps and `vruntime`. Processes are weighed by their "niceness" (`superrr` parameter) ensuring fair CPU time distribution. Your infinite `while true do` loops will no longer crash the server.
- **Microkernel Architecture & Userspace**: Processes run in a strictly isolated userspace environment and interact with the kernel exclusively through the `sys` API.
- **UID Permissions & Sudo**: Implements a real UNIX-like user system. The VFS respects `/etc/permissions.conf` based on the process's UID. Need root access? Use `sys.sudo` to authenticate against a SHA-256 hashed `/etc/shadow` and `/etc/group` to temporarily elevate to `UID 0`.
- **Advanced Virtual File System (VFS)**: A fully sandboxed I/O layer. Each process gets:
  - Its own isolated Current Working Directory (CWD).
  - Inheritable File Descriptors (0: stdin, 1: stdout, 2: stderr).
  - Inter-Process Communication (IPC) via in-memory pipes (`sys.pipe`).
  - Virtual devices (`/dev/null`, `/dev/random`, `/dev/zero`).
- **Network Sockets Subsystem**: Treat modems like real network interfaces. Create sockets (`sys.socket()`), bind to ports, and connect to remote computers. The kernel routes physical `modem_message` events directly to the correct isolated file descriptor buffer.
- **Kernel-Level RNG & Crypto**: A built-in Fortuna-based entropy pool. It gathers "true" entropy from system event jitter, OS clock, and hardware timings to feed `/dev/random`, providing random bytes for cryptographic libraries. The `sys` API also natively exposes ChaCha20 encryption and SHA-256. _(This is Lua, for fuck’s sake — what the hell do you want me to do? SquidDev, if you see this, at least add the game’s own entriopia. I’m gonna lose my damn mind.)_
- **Smart Event Dispatcher**: The scheduler is highly optimized. It tracks thread event filters natively, meaning threads are only awakened when their specific yielded event (or a termination signal) occurs, saving massive amounts of CPU cycles.
- **Enhanced Terminal Interface**: The standard `read()` function has been completely rewritten inside the sandbox. It features native command history (up/down arrows), tab-autocompletion support, and standard terminal shortcuts (like `Ctrl+L` to clear, `Ctrl+D` to exit).

## Installation

Assuming you are using **[iDar-Pacman](https://github.com/DarThunder/iDar-Pacman)** (which you should (must) be!), installation is as simple as:

```bash
pacman -S idar-loom

```

_(Alternatively, you can manually clone the `/src/` files into your project)._

## Usage

Using iDar-Loom is straightforward. You import the core, load the apps you want to run simultaneously, and start the kernel.

### Basic Implementation

Create a file called `core.lua` and use the `launch` API:

```lua
local loom = require("iDar.opt.Loom.src.core")

-- Launch as many applications as you need
loom.launch("/apps/heavy_miner.lua")
loom.launch("/apps/gui_dashboard.lua")
-- Launch a process with higher priority (niceness/superrr)
loom.launch("/apps/background_server.lua", { superrr = 2 })

-- Start the kernel (This will block and handle everything)
loom.execute()

```

### Configuration

You can tweak the scheduler's behavior before calling `execute()` if your modpack has different tick rate limitations:

```lua
local loom = require("iDar.opt.Loom.src.core")

loom.setBaseTime(300)      -- Base time limit in ms
loom.setExtensionTime(100) -- Extra time granted if forced to yield
loom.setMaxTime(1000)      -- Absolute maximum time limit

loom.launch("/my_app.lua")
loom.execute()

```

## The `sys` API

Once a program is running inside Loom, it has access to the powerful `sys` table, acting as standard system calls:

- **Process Management**:
- `sys.spawn(path, options, ...)`: Spawns a child process. Children can inherit file descriptors and UIDs from their parents.
- `sys.wait(pid)`: Yields the current process until the specified child process terminates.
- `sys.set_foreground(pid)`: Grants terminal input control to a specific process.

- **Security & Users**:
- `sys.sudo(username, password, app_route, options)`: Authenticates against `/etc/shadow` and spawns a child process as `UID 0` (root).
- `sys.getuid()`: Returns the Current User ID of the process.

- **File & IPC Management**:
- `sys.open()`, `sys.read()`, `sys.write()`, `sys.close()`: Standard VFS handlers.
- `sys.pipe()`: Creates an anonymous pipe, returning a read and write file descriptor for memory-based IPC.

- **Networking (Sockets)**:
- `sys.socket()`: Creates a new network socket file descriptor.
- `sys.bind(fd, port)`: Binds the socket to a local modem port.
- `sys.connect(fd, remote_id, remote_port)`: Establishes a connection to a remote computer.
- `sys.send(fd, data)` / `sys.recv(fd)`: Send and receive data seamlessly over the network.

- **Cryptography**:
- `sys.encrypt(message, secret, nonce)`: Fast ChaCha20 stream cipher.
- `sys.sha256(data)`: Native kernel-level hashing.

- **Directory Operations**:
- `sys.set_cwd(path)`, `sys.get_cwd()`: Manage the process's isolated working directory.
- `sys.mkdir()`, `sys.move()`, `sys.delete()`: Sandboxed filesystem manipulation.

## How it Works

Loom wraps every loaded application inside a custom environment and a sandboxed `coroutine`. It injects a hook (`scheduler.force_round_robin`) that triggers every `x` instructions. If the thread has been running for longer than its allocated time slice, the kernel forces a `coroutine.yield()`.

The scheduler then calculates the thread's **`vruntime`** (virtual runtime, adjusted by its `superrr` weight) and inserts it into a **Min-Heap**. The thread with the lowest `vruntime` at the top of the heap is always the next one to be executed. This guarantees that CPU-bound and I/O-bound processes share the processor fairly.

Simultaneously, the kernel manages a **Virtual File System (VFS)**. When a process attempts to read a file, output text, or send a network packet, the request goes through the `sys` API. This allows Loom to verify UID permissions and seamlessly redirect output to a standard terminal UI, a physical file, a remote computer, or directly into the input buffer of another running process via pipes, ensuring strict isolation and robust system stability.

## FAQ

**Q: Will this fix my terrible, unoptimized code?**
A: Yes! If you write a loop that calculates 1 billion digits of Pi without yielding, CC: Tweaked would normally kill it. Loom will pause it, recalculate its `vruntime`, let other programs run, and resume your terrible code exactly where it left off.

**Q: Does using hooks slow down execution?**
A: Slightly. There is a small overhead introduced by the instruction counter, but it is a necessary trade-off to achieve true concurrency, system stability, and kernel-level process management.

**Q: Why rewrite the `parallel` API?**
A: The default `parallel.waitForAll` relies on standard coroutine behavior. Loom injects custom thread metadata into its own environment, meaning standard CC:T parallel functions would get confused. We rewrote them so your apps can still use standard parallel syntax seamlessly inside the sandbox. _(But not everything else — the rest is already broken, and you'll be going two weeks without knowing why lol)_

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
