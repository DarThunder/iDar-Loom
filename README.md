# iDar-Loom

![State: Alpha 1](https://img.shields.io/badge/State-Alpha_1-blue)

**The preemptive multitasking kernel and task scheduler for ComputerCraft: Tweaked.**

> _"Too long without yielding? Not on my watch."_

**iDar-Loom** is a robust execution engine built to solve one of the most annoying problems in CC: Tweaked: the dreaded `"Too long without yielding"` error. It acts as a lightweight kernel that implements **true preemptive multitasking** using a Round-Robin scheduler.

Instead of relying on developers to manually place `os.sleep()` or `coroutine.yield()` inside heavy computational loops, Loom automatically intercepts and suspends CPU-hogging threads, allowing multiple complex applications to run in parallel without ever freezing the in-game computer.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [Basic Implementation](#basic-implementation)
  - [Configuration](#configuration)
- [How it Works](#how-it-works)
- [FAQ](#faq)
- [License](#license)

## Features

- **Preemptive Multitasking**: Automatically interrupts and yields heavy processes using `debug.sethook()`. Your infinite `while true do` loops will no longer crash the server.
- **Sandboxed Environment**: Applications are launched in a secure environment with overridden standard libraries (`os`, `coroutine`, `parallel`, `sleep`) to ensure they communicate perfectly with the scheduler without breaking the system.
- **Custom Event Dispatcher**: Generates internal `kernel_tick` events to keep pure-CPU applications running smoothly even when there are no real CC:T events in the queue.
- **Configurable Time Slices**: You can easily adjust the base execution time, extension times, and hook instructions to balance performance and responsiveness.
- **Ecosystem Ready**: Designed to work flawlessly alongside heavy libraries like [`iDar-BigNum`](https://github.com/DarThunder/iDar-BigNum) or [`iDar-CryptoLib`](https://github.com/DarThunder/iDar-CryptoLib).

## Installation

Assuming you are using **[iDar-Pacman](https://github.com/DarThunder/iDar-Pacman)** (which you should be!), installation is as simple as:

```bash
pacman -S idar-loom

```

_(Alternatively, you can manually clone the `/src/` files into your project)._

## Usage

Using iDar-Loom is straightforward. You import the core, load the apps you want to run simultaneously, and start the scheduler.

### Basic Implementation

Create a file called `core.lua` and use the `launch` API:

```lua
local loom = require("iDar.Loom.src.core")

-- Launch as many applications as you need
loom.launch("/apps/heavy_miner.lua")
loom.launch("/apps/gui_dashboard.lua")
loom.launch("/apps/background_server.lua")

-- Start the kernel (This will block and handle everything)
loom.execute()

```

### Configuration

You can tweak the scheduler's behavior before calling `execute()` if your modpack has different tick rate limitations:

```lua
local loom = require("iDar.Loom.src.core")

loom.setBaseTime(300)      -- Base time limit in ms
loom.setExtensionTime(100) -- Extra time granted if forced to yield
loom.setMaxTime(1000)      -- Absolute maximum time limit

loom.launch("/my_app.lua")
loom.execute()

```

## How it Works

Loom wraps every loaded application inside a custom `coroutine`. It injects a hook (`scheduler.force_round_robin`) that triggers every `x` instructions. If the thread has been running for longer than its allocated time slice (`base_time`), the hook forces a `coroutine.yield()`. The main scheduler then captures this yield, saves the thread's state, and gives the next program in the queue a chance to use the CPU.

## FAQ

**Q: Will this fix my terrible, unoptimized code?**
A: Yes! If you write a loop that calculates 1 billion digits of Pi without yielding, CC: Tweaked would normally kill it. Loom will pause it, let other programs run, and resume your terrible code exactly where it left off.

**Q: Does using hooks slow down execution?**
A: Slightly. There is a small overhead introduced by the instruction counter, but it is a necessary trade-off to achieve true concurrency and system stability.

**Q: Why rewrite the `parallel` API?**
A: The default `parallel.waitForAll` relies on standard coroutine behavior. Loom injects custom thread metadata into its own environment, meaning standard CC:T parallel functions would get confused. We rewrote them so your apps can still use standard parallel syntax seamlessly inside the sandbox.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
