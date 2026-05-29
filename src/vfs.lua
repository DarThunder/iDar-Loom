local krng = require("iDar.opt.Loom.krng")

local vfs = {}

local process_table = {}
local port_map = {}

local FD_TYPE = {
    TERM = "term",
    FILE = "file",
    PIPE = "pipe",
    NULL = "null",
    RAND = "rand",
    ZERO = "zero",
    SOCKET = "socket"
}

local permissions_cache = nil

local function load_permissions()
    if permissions_cache then return permissions_cache end

    local path = "/iDar/etc/permissions.conf"
    if fs.exists(path) then
        local handle = fs.open(path, "r")
        if handle then
            local content = handle.readAll()
            handle.close()
            local chunk = load(content, "permissions.conf", "t", {})
            if chunk then
                permissions_cache = chunk()
            end
        end
    end

    return permissions_cache or { all = "r", ["/"] = { perms = "rx", owner = 0 } }
end

local function check_permission(pid, virtual_path, requested_perm)
    local state = process_table[pid]
    if not state then return false, "Process out of bounds" end

    if state.uid == 0 then return true end

    local perms_db = load_permissions()
    local current_path = virtual_path
    local rule = nil

    while current_path ~= "" do
        if perms_db[current_path] then
            rule = perms_db[current_path]
            break
        end
        if current_path == "/" then break end
        current_path = vfs.get_dir(current_path)
    end

    local available_perms = ""
    if rule then
        if state.uid == rule.owner then
            available_perms = rule.perms or ""
        else
            available_perms = rule.all or perms_db.all or "r"
        end
    else
        available_perms = perms_db.all or "r"
    end

    if string.find(available_perms, requested_perm) then
        return true
    end

    return false, "Permission denied"
end

local function get_absolute_virtual_path(state, user_path)
    local base_path = user_path:byte(1) == 47 and user_path or fs.combine(state.cwd, user_path)
    return "/" .. fs.combine("", base_path)
end

local function resolve_safe_path(root, cwd, user_path)
    local base_path

    base_path = user_path:byte(1) == 47 and user_path or fs.combine(cwd, user_path)

    return fs.combine(root, fs.combine("", base_path))
end

function vfs.register_process(pid, root_path, options)
    local parent_pid = options and options.parent_pid
    local parent_state = parent_pid and process_table[parent_pid]

    local my_tty
    if options and options.inherit_tty and parent_state then
        my_tty = parent_state.tty
    else
        local w, h = term.getSize()
        my_tty = window.create(term.current(), 1, 1, w, h, false)
    end

    process_table[pid] = {
        root = root_path or "/iDar",
        cwd = (options and options.cwd) or "/",
        uid = (options and options.uid) or (parent_state and parent_state.uid) or 0, --putting this 0 for fallback is the dumbest idea ever, but it's an alpha, don't judge me
        fds = {},
        tty = my_tty,
        is_foreground = false
    }

    local state = process_table[pid]

    local inherited_fds = options and options.fds

    if inherited_fds and parent_pid and process_table[parent_pid] then
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

function vfs.register_port(pid, fd, local_port, remote_id)
    port_map[local_port] = {
        pid = pid,
        fd = fd,
        remote_id = remote_id
    }
end

function vfs.unregister_port(port)
    port_map[port] = nil
end

function vfs.route_network_packet(sender_id, local_port, message)
    local owner = port_map[local_port]

    if not owner then return end
    if owner.remote_id and owner.remote_id ~= sender_id then
        return
    end

    local state = process_table[owner.pid]

    if not state then
        vfs.unregister_port(local_port)
        return
    end

    local fd_obj = state.fds[owner.fd]
    if not fd_obj or fd_obj.type ~= "socket" then return end

    fd_obj.buffer = fd_obj.buffer or {}

    if #fd_obj.buffer >= 50 then
        table.remove(fd_obj.buffer, 1)
    end

    table.insert(fd_obj.buffer, {
        sender = sender_id,
        payload = message
    })

    os.queueEvent("socket_data_" .. owner.pid .. "_" .. owner.fd)
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

    local virtual_path = get_absolute_virtual_path(state, path)
    local req_perm = (mode == "r") and "r" or "w"
    local has_perm, err = check_permission(pid, virtual_path, req_perm)
    if not has_perm then return nil, err end

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

local function tty_write(target_term, text)
    local w, h = target_term.getSize()
    local start = 1

    while start <= #text do
        local cx, cy = target_term.getCursorPos()
        local space_left = w - cx + 1

        local nl = text:find("\n", start)

        if nl and (nl - start) < space_left then
            target_term.write(text:sub(start, nl - 1))
            if cy >= h then
                target_term.scroll(1)
                target_term.setCursorPos(1, h)
            else
                target_term.setCursorPos(1, cy + 1)
            end
            start = nl + 1
        else
            local chunk_end = start + space_left - 1

            if chunk_end >= #text then
                target_term.write(text:sub(start))
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
                    target_term.write(text:sub(start, last_space - 1))
                    start = last_space + 1
                else
                    target_term.write(text:sub(start, chunk_end))
                    start = chunk_end + 1
                end

                if cy >= h then
                    target_term.scroll(1)
                    target_term.setCursorPos(1, h)
                else
                    target_term.setCursorPos(1, cy + 1)
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
            state.tty.setTextColor(colors.red)
            tty_write(state.tty, text)
            state.tty.setTextColor(old)
        else
            tty_write(state.tty, tostring(data))
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
    elseif fd_obj.type == FD_TYPE.SOCKET then
        fd_obj.buffer = fd_obj.buffer or {}

        while #fd_obj.buffer == 0 do
            coroutine.yield("socket_data_" .. pid .. "_" .. fd)
        end

        return table.remove(fd_obj.buffer, 1)
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
        elseif fd_obj.type == FD_TYPE.SOCKET then
                if fd_obj.local_port then
                    vfs.unregister_port(fd_obj.local_port)
                end
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

function vfs.socket(pid)
    local state = process_table[pid]
    if not state then return nil, "Process not found" end

    local fd = get_next_fd(pid)
    state.fds[fd] = {
        type = FD_TYPE.SOCKET,
        status = "CLOSED",
        local_port = nil,
        remote_port = nil,
        crypto_key = nil,
        buffer = {}
    }
    return fd
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
        get_capacity = function(path) return vfs.get_capacity(pid, path) end,
        get_free_space = function(path) return vfs.get_free_space(pid, path) end,
        get_cwd = function() return process_table[pid].cwd end,
        set_cwd = function(new_path) return vfs.set_cwd(pid, new_path) end,
        get_tty = function() return process_table[pid].tty end,
        get_process = function(target_pid) return process_table[target_pid] end,
        socket = function() return vfs.socket(pid) end,
        register_port = function(fd, port, id) return vfs.register_port(pid, fd, port, id) end
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

    local virtual_path = get_absolute_virtual_path(state, path)
    local has_perm, err = check_permission(pid, virtual_path, "w")
    if not has_perm then return false, err end

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

    local virtual_path = get_absolute_virtual_path(state, path)
    local has_perm, err = check_permission(pid, virtual_path, "w")
    if not has_perm then
        return false, err
    end

    local real_path = resolve_safe_path(state.root, state.cwd, path)

    if not fs.exists(real_path) then
        return false, "File or directory does not exists"
    end

    local success, err_msg = pcall(function ()
        fs.delete(real_path)
    end)

    if success then
        return true
    else
        return false, err_msg or "Unknown error"
    end
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