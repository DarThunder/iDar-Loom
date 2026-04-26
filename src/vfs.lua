local krng = require("iDar.opt.Loom.krng")

local vfs = {}

local process_table = {}

local FD_TYPE = {
    TERM = "term",
    FILE = "file",
    PIPE = "pipe",
    NULL = "null",
    RAND = "rand",
    ZERO = "zero"
}

local function resolve_safe_path(root, cwd, user_path)
    local base_path

    base_path = user_path:byte(1) == 47 and user_path or fs.combine(cwd, user_path)

    return fs.combine(root, fs.combine("", base_path))
end

function vfs.register_process(pid, root_path, options)
    process_table[pid] = {
        root = root_path or "/iDar",
        cwd = (options and options.cwd) or "/",
        fds = {}
    }

    local state = process_table[pid]

    local inherited_fds = options and options.fds
    local parent_pid = options and options.parent_pid

    if inherited_fds and parent_pid and process_table[parent_pid] then
        local parent_state = process_table[parent_pid]

        for child_fd, parent_fd in pairs(inherited_fds) do
            if parent_state.fds[parent_fd] then
                state.fds[child_fd] = parent_state.fds[parent_fd]
            end
        end
    else
        state.fds[0] = { type = FD_TYPE.TERM, mode = "r" }
        state.fds[1] = { type = FD_TYPE.TERM, mode = "w" }
        state.fds[2] = { type = FD_TYPE.TERM, mode = "w" }
    end
end

local function get_next_fd(pid)
    local fds = process_table[pid].fds
    local fd = 3
    while fds[fd] ~= nil do
        fd = fd + 1
    end
    return fd
end

function vfs.open(pid, path, mode)
    local state = process_table[pid]

    if not state then return nil, "Process out of bounds" end

    if path == "/dev/null" then
        local fd = get_next_fd(pid)
        state.fds[fd] = {
            type = FD_TYPE.NULL,
            mode = mode
        }
        return fd
    elseif path == "/dev/random" then
        local fd = get_next_fd(pid)
        state.fds[fd] = {
            type = FD_TYPE.RAND,
            mode = "r"
        }
        return fd
    elseif path == "/dev/zero" then
        local fd = get_next_fd(pid)
        state.fds[fd] = {
            type = FD_TYPE.ZERO,
            mode = "r"
        }
        return fd
    end

    local real_path = resolve_safe_path(state.root, state.cwd, path)
    local handle = fs.open(real_path, mode)

    if not handle then return nil, "Cannot open: " .. path end

    local fd = get_next_fd(pid)
    state.fds[fd] = {
        type = FD_TYPE.FILE,
        mode = mode,
        handle = handle,
        real_path = real_path
    }

    return fd
end

local function tty_write(text)
    local w, h = term.getSize()
    local start = 1

    while start <= #text do
        local cx, cy = term.getCursorPos()
        local space_left = w - cx + 1

        local nl = text:find("\n", start)

        if nl and (nl - start) < space_left then
            term.write(text:sub(start, nl - 1))
            if cy >= h then
                term.scroll(1)
                term.setCursorPos(1, h)
            else
                term.setCursorPos(1, cy + 1)
            end
            start = nl + 1
        else
            local chunk_end = start + space_left - 1

            if chunk_end >= #text then
                term.write(text:sub(start))
                break
            else
                local last_space = nil
                for i = chunk_end, start, -1 do
                    if text:byte(i) == 32 then
                        last_space = i
                        break
                    end
                end

                if last_space then
                    term.write(text:sub(start, last_space - 1))
                    start = last_space + 1
                else
                    term.write(text:sub(start, chunk_end))
                    start = chunk_end + 1
                end

                if cy >= h then
                    term.scroll(1)
                    term.setCursorPos(1, h)
                else
                    term.setCursorPos(1, cy + 1)
                end
            end
        end
    end
end

function vfs.write(pid, fd, data)
    local state = process_table[pid]
    local fd_obj = state.fds[fd]

    if not fd_obj then return false, "Bad file descriptor" end
    if fd_obj.mode == "r" then return false, "FD opened for reading only" end

    local text = tostring(data)

    if fd_obj.type == FD_TYPE.TERM then
        if fd == 2 then
            local old = term.getTextColor()
            term.setTextColor(colors.red)
            tty_write(text)
            term.setTextColor(old)
        else
            tty_write(text)
        end
        return true
    elseif fd_obj.type == FD_TYPE.FILE then
        fd_obj.handle.write(text)
        return true
    elseif fd_obj.type == FD_TYPE.PIPE then
        fd_obj.buffer.data = fd_obj.buffer.data .. text
        return true
    elseif fd_obj.type == FD_TYPE.NULL then
        return true
    end
end

function vfs.read(pid, fd)
    local state = process_table[pid]
    local fd_obj = state.fds[fd]

    if not fd_obj then return nil, "Bad file descriptor" end

    if fd_obj.type == FD_TYPE.TERM and fd == 0 then
        local event_data = table.pack(coroutine.yield("tty_data_" .. pid))
        return event_data[2]
    elseif fd_obj.type == FD_TYPE.FILE then
        if fd_obj.handle.readAll then
            return fd_obj.handle.readAll()
        end
    elseif fd_obj.type == FD_TYPE.PIPE then
        local data = fd_obj.buffer.data
        fd_obj.buffer.data = ""
        return data
    elseif fd_obj.type == FD_TYPE.NULL then
        return nil
    elseif fd_obj.type == FD_TYPE.RAND then
        --this shit is not random and definitely is not a CSRNG, but it's CC: Tweaked, leave me alone
        return krng.read_random_bytes(32)
    elseif fd_obj.type == FD_TYPE.ZERO then
        return 0
    end
end

function vfs.read_line(pid, fd)
    local state = process_table[pid]
    local fd_obj = state.fds[fd]

    if not fd_obj then return nil, "Bad file descriptor" end

    if fd_obj.type == FD_TYPE.TERM and fd == 0 then
        local event_data = table.pack(coroutine.yield("tty_data_" .. pid))
        return event_data[2]

    elseif fd_obj.type == FD_TYPE.FILE then
        if fd_obj.handle.readLine then
            return fd_obj.handle.readLine()
        end

    elseif fd_obj.type == FD_TYPE.PIPE then
        local data = fd_obj.buffer.data
        if data == "" then return nil end

        local nl = data:find("\n")
        if nl then
            local line = data:sub(1, nl - 1)
            fd_obj.buffer.data = data:sub(nl + 1)
            return line
        else
            local line = data
            fd_obj.buffer.data = ""
            return line
        end
    end
    return nil
end

function vfs.close(pid, fd)
    if fd <= 2 then return false, "Cannot close standard FDs" end

    local state = process_table[pid]
    local fd_obj = state.fds[fd]

    if fd_obj then
        if fd_obj.type == FD_TYPE.FILE then
            fd_obj.handle.close()
        end
        state.fds[fd] = nil
        return true
    end
    return false
end

function vfs.pipe(pid)
    local state = process_table[pid]

    local pipe_buffer = { data = "" }

    local fd_read = get_next_fd(pid)
    state.fds[fd_read] = { type = FD_TYPE.PIPE, mode = "r", buffer = pipe_buffer }

    local fd_write = get_next_fd(pid)
    state.fds[fd_write] = { type = FD_TYPE.PIPE, mode = "w", buffer = pipe_buffer }

    return fd_read, fd_write
end

function vfs.create_syscalls(pid)
    return {
        open = function(path, mode) return vfs.open(pid, path, mode) end,
        write = function(fd, data) return vfs.write(pid, fd, data) end,
        read = function(fd) return vfs.read(pid, fd) end,
        close = function(fd) return vfs.close(pid, fd) end,
        pipe = function() return vfs.pipe(pid) end,
        exists = function(path) return vfs.exists(pid, path) end,
        is_dir = function(path) return vfs.is_dir(pid, path) end,
        list = function(path) return vfs.list(pid, path) end,
        read_line = function(fd) return vfs.read_line(pid, fd) end,
        mkdir = function(path) return vfs.make_dir(pid, path) end,
        get_dir = function(path) return vfs.get_dir(path) end,
        move = function(path_init, path_dest) return vfs.move(pid, path_init, path_dest) end,
        delete = function(path) return vfs.delete(pid, path) end,
        dofile = function(path) return vfs.dofile(pid, path) end,
        get_capacity = function(path) return vfs.get_capacity(pid, path) end,
        get_free_space = function(path) return vfs.get_free_space(pid, path) end,
        get_cwd = function() return process_table[pid].cwd end,
        set_cwd = function(new_path) return vfs.set_cwd(pid, new_path) end,
    }
end

function vfs.set_cwd(pid, new_path)
    local state = process_table[pid]
    if not state then return false end

    local real_path = resolve_safe_path(state.root, state.cwd, new_path)
    if fs.exists(real_path) and fs.isDir(real_path) then
        if real_path == "iDar" then state.cwd = "/" end

        local clean_virtual = fs.combine(state.cwd, new_path)
        state.cwd = "/" .. fs.combine("", clean_virtual)
        return true
    end
    return false
end

function vfs.cleanup_process(pid)
    local state = process_table[pid]
    if state then
        for fd, obj in pairs(state.fds) do
            if fd > 2 and obj.type == FD_TYPE.FILE then
                obj.handle.close()
            end
        end
        process_table[pid] = nil
    end
end

function vfs.kernel_read_file(root_path, cwd_path, user_path)
    local real_path = resolve_safe_path(root_path, cwd_path, user_path)

    if not fs.exists(real_path) then return nil, "File not found: " .. real_path end

    local handle = fs.open(real_path, "r")
    if not handle then return nil, "Cannot open: " .. real_path end

    local content = handle.readAll()
    handle.close()

    return content
end

function vfs.exists(pid, path)
    local state = process_table[pid]

    if path == "/dev/null" or path == "/dev/random" or path == "/dev/zero" then
        return true
    end

    local real_path = resolve_safe_path(state and state.root, state.cwd, path)
    return fs.exists(real_path)
end

function vfs.is_dir(pid, path)
    local state = process_table[pid]

    if path == "/dev/null" or path == "/dev/random" or path == "/dev/zero" then
        return false
    end

    local real_path = resolve_safe_path(state and state.root, state.cwd, path)
    return fs.isDir(real_path)
end

function vfs.list(pid, path)
    local state = process_table[pid]
    local real_path = resolve_safe_path(state and state.root, state.cwd, path)

    if fs.exists(real_path) and fs.isDir(real_path) then
        return fs.list(real_path)
    end
    return {}
end

function vfs.make_dir(pid, path)
    local state = process_table[pid]
    if not state then return false, "Process not found" end

    local real_path = resolve_safe_path(state.root, state.cwd, path)

    if fs.exists(real_path) then
        return false, "File or directory already exists"
    end

    local success, err = pcall(function()
        fs.makeDir(real_path)
    end)

    if success then
        return true
    else
        return false, err or "Unknown error"
    end
end

function vfs.get_dir(path)
    if path == "" or path == "/" then
        return "/"
    end

    local parent_dir = string.match(path, "^(.*)/[^/]*$")
    if not parent_dir then
        return ""
    end

    if parent_dir == "" then
        return "/"
    end

    return parent_dir
end

function vfs.move(pid, path_init, path_dest, recursive)
    local state = process_table[pid]
    if not state then return false, "Process not found" end

    local real_path_init = resolve_safe_path(state.root, state.cwd, path_init)
    local real_path_dest = resolve_safe_path(state.root, state.cwd, path_dest)

    if not fs.exists(real_path_init) and not fs.exists(real_path_dest) then
        return false, "File or directory already exists"
    end

    fs.move(real_path_init, real_path_dest)
end

function vfs.delete(pid, path)
    local state = process_table[pid]
    if not state then return false, "Process not found" end

    local real_path = resolve_safe_path(state.root, state.cwd, path)

    if not fs.exists(real_path) then
        return false, "File or directory does not exists"
    end

    local success, err = pcall(function ()
        fs.delete(real_path)
    end)

    if success then
        return true
    else
        return false, err or "Unknown error"
    end
end

function vfs.dofile(pid, path)
    local state = process_table[pid]
    if not state then return false, "Process not found" end

    local real_path = resolve_safe_path(state.root, state.cwd, path)

    if not fs.exists(real_path) then
        return false, "File or directory does not exists"
    end

    return dofile(real_path)
end

function vfs.get_capacity(pid, path)
    local state = process_table[pid]
    if not state then return false, "Process not found" end

    local real_path = resolve_safe_path(state.root, state.cwd, path)

    if not fs.exists(real_path) then
        return false, "File or directory does not exists"
    end

    return fs.getCapacity(real_path)
end

function vfs.get_free_space(pid, path)
    local state = process_table[pid]
    if not state then return false, "Process not found" end

    local real_path = resolve_safe_path(state.root, state.cwd, path)

    if not fs.exists(real_path) then
        return false, "File or directory does not exists"
    end

    return fs.getFreeSpace(real_path)
end

return vfs