# RFC-0001: Co-routine Intent Specification Standard (CISS)

**Architecture:** iDar-OS / Loom Kernel
**Document Version:** 1.0-Alpha

## 1. Abstract

The **Co-routine Intent Specification Standard (CISS)** defines the Application Binary Interface (ABI) for communication between userland and the Kernel (Loom).

CISS deprecates direct API injection into the process's global environment (`_G` or `env`). Instead, it establishes a secure, asynchronous, and isolated model based on message passing, using controlled interruption of the execution thread via `coroutine.yield()`.

## 2. Calling Convention

Any request to the kernel must be issued by yielding control of the process's main coroutine. The CISS convention requires a strict table-based payload structure for the request, and a CISS-style `errno` system for the return.

**Request Structure:**
Unlike standard Lua yields, CISS requires the payload to be wrapped in a single sequential table:

```lua
coroutine.yield({CATEGORY_ID, COMMAND_ID, arg1, arg2, ...})
```

**Return Structure:**
The kernel resumes the coroutine with the resulting data or a negative error code (mapped to CISS `errno`).

```lua
local result_or_errno = coroutine.yield({...})
if type(result_or_errno) == "number" and result_or_errno < 0 then
    -- Handle error (e.g., -errno.ENOENT)
end
```

## 3. Interrupt Categories (Field 1)

The first argument (Field 1) defines the logical bus or subsystem the request is directed to.

- **`0x01`**: Syscalls (Base System, I/O, Process Management, and Networking).
- **`0x02`**: Event Management (Conceptually assigned to replace event polling).
- **`0x03`**: Time Control / Sleep.

## 4. System and VFS Syscalls (Category `0x01`)

When the first field (Category ID) is `0x01`, the second field (Command ID) determines the exact operation. CISS intentionally mirrors standard CISS hexadecimal IDs for system calls to maintain architectural consistency.

### 4.1. Core Syscall Reference

| Command ID (Hex) | CISS Name  | Arguments | Short Description                  |
| ---------------- | ---------- | --------- | ---------------------------------- |
| `0x00`           | `SYS_READ` | `(fd)`    | Reads data from a file descriptor. |

|
| `0x01` | `SYS_WRITE` | `(fd, data)` | Writes data to a file descriptor.

|
| `0x02` | `SYS_OPEN` | `(path, mode)` | Opens a file and returns a new FD.

|
| `0x03` | `SYS_CLOSE` | `(fd)` | Closes an open file descriptor.

|
| `0x04` | `SYS_STAT` | `(path)` | Retrieves metadata/status of a file or directory.

|
| `0x16` | `SYS_PIPE` | `()` | Creates an anonymous unidirectional IPC channel.

|
| `0x4F` | `SYS_GETCWD` | `()` | Retrieves the current working directory of the process.

|
| `0x50` | `SYS_CHDIR` | `(path)` | Changes the process's working directory.

|
| `0x52` | `SYS_RENAME` | `(src, dst)` | Moves or renames a file or directory.

|
| `0x53` | `SYS_MKDIR` | `(path)` | Creates a new directory.

|
| `0x54` | `SYS_RMDIR` | `(path)` | Removes an empty directory.

|
| `0x57` | `SYS_UNLINK` | `(path)` | Deletes a file node.

|
| `0x89` | `SYS_STATFS` | `(path)` | Retrieves filesystem statistics (capacity/free space).

|
| `0xD9` | `SYS_GETDENTS64` | `(path)` | Lists directory contents.

|
| `0xE4` | `SYS_CLOCK_GETTIME` | `(clock_type)` | Retrieves time (monotonic, realtime, or in-game).

|

### 4.2. Standardized File Descriptors (FDs)

The Virtual File System (VFS) guarantees the existence of standard file descriptors and virtual device files:

- **System FDs (CISS compliant):**
- `0`: Standard Input (Mapped to type `TERM`, read mode).

- `1`: Standard Output (Mapped to type `TERM`, write mode).

- `2`: Standard Error (Mapped to type `TERM`, write mode, rendered in red by default).

- **Virtual Devices (Special FD Types):**
- `/dev/null`: Discards writes, returns `nil` on read (Type `NULL`).

- `/dev/random`: Returns pseudo-random sequences via the `krng` cryptographic module (Type `RAND`).

- `/dev/zero`: Constantly returns `0` (Type `ZERO`).

### 4.3. Process & Network Control Operations

String-based process management has been deprecated in CISS. All process, network, and security controls now strictly adhere to the `0x01` Category bus using hexadecimal IDs.

**Process Management & Security:**

- **`0x27` (`SYS_GETPID`)**: Requests the active process ID.

- **`0x3B` (`SYS_EXECVE`)**: Spawns a new child process, parsing SUID bits and cloning standard FDs. Arguments: `(app_route, options, ...)`.

- **`0x3C` (`SYS_EXIT`)**: Terminates the calling process with a specific exit code.

- **`0x3D` (`SYS_WAIT`)**: Blocks the active coroutine until a specified child process terminates.

- **`0x3E` (`SYS_KILL`)**: Sends a termination signal to a target process (Requires UID 0 or process ownership).

- **`0x66` (`SYS_GETUID`)**: Returns the effective and real User ID.

- **`0x69` (`SYS_SETUID`)**: Sets the effective User ID.

- **`0x201` (`SYS_ASSIGN_TTY`)**: Requests the kernel to bring a specific process to the foreground of a target Virtual Console.

**Network Sockets (Modem Abstraction):**

- **`0x29` (`SYS_SOCKET`)**: Allocates a new network socket file descriptor.

- **`0x31` (`SYS_BIND`)**: Binds a socket to a local port.

- **`0x2A` (`SYS_CONNECT`)**: Connects a socket to a remote ID and port.

- **`0x2C` (`SYS_SEND`)**: Sends a packet through the established socket.

## 5. Userland Implementation

The CISS design dictates that the verbosity of `coroutine.yield()` should not fall on the end programmer. Instead, the operating system provides a standard dynamic library (`sys.lua`) that wraps CISS calls.

**Example implementation of the standard library (sys.read):**

```lua
function sys.read(fd, buffer, size)
    -- The kernel takes control here via CISS
    local ok, data = coroutine.yield(0x01, 0x03, fd, buffer, size)

    if not ok then return ok, data end

    return data
end
```
