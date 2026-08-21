# iDar-Loom

![State: Alpha 4](https://img.shields.io/badge/State-Alpha_4-orange)

**The preemptive multitasking CISS kernel, CFS scheduler, and execution engine for ComputerCraft: Tweaked.**

> _"Too long without yielding? Not on my watch."_

**iDar-Loom** has evolved far beyond a simple task scheduler. It is a robust, lightweight **CISS monolithic kernel** built to solve the most annoying problems in CC: Tweaked: the dreaded `"Too long without yielding"` error, lack of process isolation, non-existent security, and poor inter-process communication.

Loom brings Linux-grade OS concepts to a Minecraft mod: **true preemptive multitasking** using a Completely Fair Scheduler (CFS) with Min-Heaps, a strictly sandboxed user environment, a real UID-based permission system, virtual TTY consoles with ANSI support, and a powerful interrupt-driven syscall API. Multiple complex applications can now run concurrently, pipe data to each other, communicate over the network, and manage their own environments without ever freezing the in-game computer.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [The CISS Syscall Interface](#the-ciss-syscall-interface)
- [How it Works](#how-it-works)
- [FAQ](#faq)
- [License](#license)

## Features

- **Preemptive CFS Multitasking**: Automatically intercepts and yields CPU-hogging processes using instruction hooks (defaulting to a 5000 instruction limit). The Completely Fair Scheduler (CFS) uses binary Min-Heaps to sort processes by their virtual runtime (`vruntime`). CPU time is distributed dynamically based on a `target_latency` (24ms) and `min_granularity` (2ms), weighed by a process's priority (`superrr` parameter).
- **Microkernel Architecture & Userspace**: Processes run in a strictly isolated userspace sandbox. Standard libraries like `setmetatable` are intercepted to prevent userspace from tampering with kernel data structures.
- **Virtual Terminals (TTY) & ANSI Support**: The TTY driver manages up to 6 independent virtual consoles simultaneously. Users can hot-swap between consoles using `Ctrl + 1-6`. The kernel natively parses ANSI escape codes for colors, cursor positioning, and line clearing.
- **UID Permissions & Security**: Implements a real UNIX-like user system where every process has an effective UID and real UID. The VFS respects access control across the filesystem.
- **Advanced Virtual File System (VFS)**: A fully sandboxed I/O layer. Features include:
  - Synthetic filesystems: `procfs` (`/proc/cpuinfo`, `/proc/meminfo`, `/proc/version`) and `sysfs`.
  - Virtual character devices: `/dev/null`, `/dev/random`, and `/dev/zero`.
  - Inheritable File Descriptors (0: stdin, 1: stdout, 2: stderr) and Inter-Process Communication (IPC) via in-memory anonymous pipes.
- **Network Sockets Subsystem**: Treat modems like real network interfaces. Create sockets, bind to ports, and connect to remote computers using file descriptors. The kernel routes physical `modem_message` events asynchronously.
- **Kernel-Level RNG & Crypto**: A built-in Fortuna-based entropy pool that gathers "true" entropy from system event jitter, OS clock, and hardware timings to feed `/dev/random`. It natively includes ChaCha20 stream cipher operations and SHA-256 hashing.

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
local core = require("iDar.boot.Loom.core")

-- Launch a base process (like your shell or init system)
core.launch("/bin/shell.lua")

-- Start the kernel (This will block and handle everything)
core.execute()

```

## The CISS Syscall Interface

Loom 4.0.0 replaces the old `sys` API table with a true software-interrupt architecture. Userspace applications communicate with Ring 0 by using `coroutine.yield` passing standard hexadecimal syscall IDs (e.g., `0x01` for write). If a syscall fails, it returns standard CISS error codes (like `-errno.EBADF` or `-errno.ENOENT`).

Normally, you don't call these directly. Instead, you interact with standard Clib (like `unistd` and `stdio`) in your userland applications:

- **Process Management**:
- `0x3B` (`execve`): Clones standard file descriptors and spawns a new process, handling SUID bit logic.

- `0x3D` (`wait`), `0x3C` (`exit`), `0x3E` (`kill`).

- **File & IPC Management**:
- `0x00` (`read`), `0x01` (`write`), `0x02` (`open`), `0x03` (`close`).

- `0x16` (`pipe`): Creates an anonymous pipe returning read/write file descriptors for IPC.

- `0x89` (`statfs`), `0x04` (`stat`).

- **Networking (Sockets)**:
- `0x29` (`socket`), `0x31` (`bind`), `0x2A` (`connect`), `0x2C` (`send`).

- **Directory Operations**:
- `0x4F` (`getcwd`), `0x50` (`chdir`).

- `0x53` (`mkdir`), `0x52` (`rename`), `0x57` (`unlink`), `0x54` (`rmdir`).

## How it Works

Loom wraps every loaded application inside a custom sandbox and a `coroutine`. It uses `debug.sethook()` to interrupt the thread after a set number of instructions.

The kernel calculates the thread's **`vruntime`** (virtual runtime, adjusted by its `superrr` weight) and inserts it into a **Min-Heap**. The thread with the lowest `vruntime` at the top of the heap is always the next one to be executed, guaranteeing that CPU-bound and I/O-bound processes share the processor fairly.

Instead of regular Lua function calls, every I/O operation (reading a file, outputting to the TTY, or sending network packets) triggers a syscall. The kernel verifies permissions against the process's UID, allowing Loom to securely redirect output to a virtual console, a physical file, or directly into the input buffer of another running process via pipes.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
