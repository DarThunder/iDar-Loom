local vfs = require("iDar.boot.Loom.fs.vfs")
local sandbox = require("iDar.boot.Loom.sec.sandbox")
local config = require("iDar.boot.Loom.boot.config")
local interrupt = require("iDar.boot.Loom.core.interrupt")

local task = {}
local next_pid = 1

function task.spawn(parent_proc, app_route, options, ...)
    local ok, fd = vfs.open(parent_proc.uid, parent_proc.root, parent_proc.cwd, app_route, "r")
    if not ok then return false, "Access denied /not found: " .. tostring(fd) end

    local ok_read, content = vfs.read(fd)
    vfs.close(fd)

    if not ok_read then return false, "Empty file: " .. tostring(content) end

    local virtual_path = app_route:byte(1) == 47 and app_route or fs.combine(parent_proc.cwd, app_route)
    virtual_path = "/" .. fs.combine("", virtual_path)
    local file_owner, _, is_suid = vfs.get_file_attributes(virtual_path)

    local effective_uid = parent_proc.uid
    if is_suid then
        effective_uid = file_owner
    end

    local pid = next_pid
    next_pid = next_pid + 1

    options = type(options) == "table" and options or {}

    if options.uid and parent_proc.uid == 0 then
        effective_uid = options.uid
    end

    options.cwd = options.cwd or parent_proc.cwd
    options.parent_pid = parent_proc.pid
    options.root = options.root or "/iDar"
    options.tty = options.tty or nil

    local env = sandbox.create(options and options.term or nil, pid)
    local func, err = load(content, app_route, "t", env)

    if not func then error("Error: " .. err) end

    local args = {...}

    local function wrapper() func(table.unpack(args)) end

    local main_co = coroutine.create(wrapper)
    debug.sethook(main_co, interrupt.force_yield, "", config.hook_instructions)

    local child_fds = {}
    if options.fds then
        for child_fd, parent_fd in pairs(options.fds) do
            child_fds[child_fd] = parent_proc.fds[parent_fd]
        end
    else
        child_fds = {
            [0] = { type = "term", mode = "r", tty = options.tty },
            [1] = { type = "term", mode = "w", tty = options.tty },
            [2] = { type = "term", mode = "w", tty = options.tty }
        }
    end

    local new_process = {
        pid = pid,
        uid = effective_uid,
        real_uid = parent_proc.uid,
        cwd = options.cwd,
        root = options.root,
        name = app_route,
        co = main_co,
        time_limit = config.min_granularity,
        start_time = 0,
        weight = 1.025 ^ (options.superrr or 0),
        superrr = options.superrr or 0,
        vruntime = parent_proc.vruntime or 0,
        pending_process = {},
        fds = child_fds
    }

    return true, pid, new_process
end

return task