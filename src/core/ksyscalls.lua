local vfs = require("iDar.boot.Loom.fs.vfs")
local task = require("iDar.boot.Loom.core.task")
local net_driver = require("iDar.boot.Loom.drivers.net")
local tty_driver = require("iDar.boot.Loom.drivers.tty")
local kstate = require("iDar.boot.Loom.core.kstate")

local syscall = {}

local errno = {
    EPERM   = 1,
    ENOENT  = 2,
    EIO     = 5,
    EBADF   = 9,
    EACCES  = 13,
    EEXIST  = 17,
    ENOTDIR = 20,
    EINVAL  = 22,
    ENOSYS  = 38
}

local ksig = {
    BLOCK = 0xA0,
    SPAWN = 0xA1,
    EXIT  = 0xA2
}

local handlers = {
    [0x00] = { name = "read", expected_args = {"number"},
        execute = function(proc, fd)
            if fd == 0 then
                local _, data = tty_driver.read(proc.pid)
                if data == "BLOCK" then return ksig.BLOCK, "tty_wait_" .. proc.pid end
                return data
            end

            local node = proc.fds[fd]

            if not node then return -errno.EBADF end
            if node.type == "socket" then
                local status, data = net_driver.recv(node, proc.pid)
                if status == "BLOCK" then return ksig.BLOCK, "net_wait_" .. proc.pid end
                return data
            end

            local ok, data_or_err = vfs.read(node)

            if not ok then return -errno.EIO end

            return data_or_err
        end
    },
    [0x01] = { name = "write", expected_args = {"number", "string|number"},
        execute = function(proc, fd, data)
            if fd <= 2 then
                tty_driver.write(proc.pid, data, (fd == 2))
                return string.len(tostring(data))
            end
            if not proc.fds[fd] then return -errno.EBADF end

            local ok = vfs.write(proc.fds[fd], data)

            if not ok then return -errno.EIO end

            return string.len(tostring(data))
        end
    },
    [0x02] = { name = "open", expected_args = {"string", "string"},
        execute = function(proc, path, mode)
            local ok, node_or_err = vfs.open(proc.uid, proc.root, proc.cwd, path, mode)

            if not ok then
                if node_or_err == "Permission denied" then return -errno.EACCES end
                return -errno.ENOENT
            end

            local fd = 3

            while proc.fds[fd] ~= nil do fd = fd + 1 end

            proc.fds[fd] = node_or_err

            return fd
        end
    },
    [0x03] = { name = "close", expected_args = {"number"},
        execute = function(proc, fd)
            local node = proc.fds[fd]

            if node then
                vfs.close(node)
                proc.fds[fd] = nil
                return 0
            end

            return -errno.EBADF
        end
    },
    [0x04] = { name = "stat", expected_args = {"string"},
        execute = function(p, path) 
            if not vfs.exists(p.uid, p.root, p.cwd, path) then return -errno.ENOENT end

            return {
                is_dir = vfs.is_dir(p.uid, p.root, p.cwd, path)
            }
        end
    },
    [0x16] = { name = "pipe",
        execute = function(proc)
            local node_read, node_write = vfs.pipe()
            local fd_read, fd_write = 3, 4

            while proc.fds[fd_read] ~= nil do fd_read = fd_read + 1 end

            proc.fds[fd_read] = node_read
            fd_write = fd_read + 1

            while proc.fds[fd_write] ~= nil do fd_write = fd_write + 1 end

            proc.fds[fd_write] = node_write

            return {fd_read, fd_write}
        end
    },
    [0x27] = { name = "getpid", execute = function(p) return p.pid end },
    [0x29] = { name = "socket", execute = function(p) return net_driver.socket(p) end },
    [0x2A] = { name = "connect", expected_args = {"number", "number"},
        execute = function(p, rid, rport) 
            return net_driver.connect(p.pid, rid, rport)
        end
    },
    [0x2C] = { name = "send", expected_args = {"number", "string"},
        execute = function(p, data)
            return net_driver.send(p.pid, data)
        end
    },
    [0x31] = { name = "bind", expected_args = {"number"},
        execute = function(p, port)
            return net_driver.bind(p.pid, port)
        end
    },
    [0x3B] = { name = "execve", expected_args = {"string", "table|nil"},
        execute = function(proc, app_route, options, ...)
            local owner, _, is_suid = vfs.get_file_attributes(app_route)

            local og_uid = proc.uid

            if is_suid then
                proc.uid = owner
            end

            local ok, new_pid, new_process = task.spawn(proc, app_route, options, ...)
            proc.uid = og_uid

            if ok and new_process then
                if proc.fds[0] and proc.fds[0].tty then
                    tty_driver.assign_process(new_pid, proc.fds[0].tty)
                end

                return ksig.SPAWN, new_pid, new_process
            end
            return -errno.ENOENT
        end
    },
    [0x3C] = { name = "exit", expected_args = {"number|nil"},
        execute = function(proc, exit_code)
            proc.killed = true
            proc.exit_code = exit_code or 0

            return ksig.EXIT
        end
    },
    [0x3D] = { name = "wait", expected_args = {"number"},
        execute = function(_, target_pid)
            return ksig.BLOCK, "wait_" .. target_pid
        end
    },
    [0x3E] = { name = "kill", expected_args = {"number"},
        execute = function(proc, target_pid)
            local target = kstate.process_table[target_pid]

            if not target then return -errno.ENOENT end
            if proc.uid ~= 0 and proc.uid ~= target.uid then return -errno.EPERM end

            target.killed = true

            return 0
        end
    },
    [0x4F] = { name = "getcwd", execute = function(p) return p.cwd end },
    [0x50] = { name = "chdir", expected_args = {"string"},
        execute = function(proc, new_path)
            local ok, np = vfs.resolve_cwd(proc.root, proc.cwd, new_path)

            if ok then
                proc.cwd = np
                return 0
            end

            return -errno.ENOENT
        end
    },
    [0x52] = { name = "rename", expected_args = {"string", "string"},
        execute = function(p, src, dst) 
            local ok = vfs.move(p.uid, p.root, p.cwd, src, dst)

            if not ok then return -errno.EACCES end

            return 0
        end
    },
    [0x53] = { name = "mkdir",  expected_args = {"string"},
        execute = function(p, path)
            local ok = vfs.make_dir(p.uid, p.root, p.cwd, path)

            if not ok then return -errno.EACCES end

            return 0
        end
    },
    [0x54] = { name = "rmdir", expected_args = {"string"},
        execute = function(p, path)
            if not vfs.is_dir(p.uid, p.root, p.cwd, path) then return -errno.ENOTDIR end

            local ok = vfs.delete(p.uid, p.root, p.cwd, path)

            if not ok then return -errno.EACCES end

            return 0
        end
    },
    [0x57] = { name = "unlink", expected_args = {"string"},
        execute = function(p, path)
            if vfs.is_dir(p.uid, p.root, p.cwd, path) then return -errno.EPERM end

            local ok = vfs.delete(p.uid, p.root, p.cwd, path)

            if not ok then return -errno.EACCES end

            return 0
        end
    },
    [0x66] = { name = "getuid", execute = function(p) return p.uid, p.real_uid end },
    [0x69] = { name = "setuid", expected_args = {"string|nil"},
        execute = function(proc, target_uid)
            if not target_uid then
                if proc.real_uid then proc.uid = proc.real_uid; return 0 end
                return -errno.EPERM
            end
            if proc.uid == 0 or proc.real_uid == target_uid then
                proc.uid = target_uid
                return 0
            end

            return -errno.EPERM
        end
    },
    [0x89] = { name = "statfs", expected_args = {"string"},
        execute = function(p, path)
            local cap, _ = vfs.get_capacity(p.uid, p.root, p.cwd, path)

            if not cap then return -errno.ENOENT end

            local free, _ = vfs.get_free_space(p.uid, p.root, p.cwd, path)

            return { capacity = cap, free = free }
        end
    },
    [0xD9] = { name = "getdents64", expected_args = {"string", "table|nil"},
        execute = function(p, path)
            local ok, list = vfs.list(p.uid, p.root, p.cwd, path)

            if not ok then return -errno.ENOENT end

            return list
        end
    },
    [0xE4] = { name = "clock_gettime", expected_args = {"string"},
        execute = function(_, clock_type)
            if clock_type == "monotonic" then return os.clock()
            elseif clock_type == "realtime" then return os.epoch("utc")
            elseif clock_type == "ingame" then return os.time() end

            return -errno.EINVAL
        end
    },
    [0x201] = { name = "assign_tty", expected_args = {"number", "number|nil"},
        execute = function(_, pid, cid)
            return tty_driver.assign_process(pid, cid)
        end
    }
}

local function validate_args(expected, args)
    if not expected then return true end

    for i, exp_types in ipairs(expected) do
        local arg_type = type(args[i])
        local matched = false

        for valid_type in string.gmatch(exp_types, "([^|]+)") do
            if arg_type == valid_type then matched = true; break end
        end

        if not matched then return false end
    end

    return true
end

function syscall.dispatch(proc, syscall_id, ...)
    local handler = handlers[syscall_id]

    if not handler then return -errno.ENOSYS end

    local args = table.pack(...)

    if not validate_args(handler.expected_args, args) then
        return -errno.EINVAL
    end

    local status = table.pack(pcall(handler.execute, proc, table.unpack(args, 1, args.n)))

    if not status[1] then
        return -errno.EIO
    end

    return table.unpack(status, 2, status.n)
end

return syscall