local krng = require("iDar.boot.Loom.sec.krng")

local vfs = {}

local NODE_TYPE = {
    FILE = "file",
    PIPE = "pipe",
    NULL = "null",
    RAND = "rand",
    ZERO = "zero",
    SOCKET = "socket",
    PROC = "proc",
    SYS = "sys"
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

local function generate_proc_content(path)
    if path == "/proc/cpuinfo" then
        local mhz = math.floor(_G.os.clock() * 1000)
        return string.format([[
            processor       : 0
            vendor_id       : Innovations DarThunder Company
            cpu family      : 1
            model           : 1
            model name      : Virtual CPU
            stepping        : 0
            microcode       : 0x1
            cpu MHz         : %d
            cache size      : 4096 KB
            physical id     : 0
            siblings        : 1
            core id         : 0
            cpu cores       : 1
            apicid          : 0
            initial apicid  : 0
            fpu             : yes
            fpu_exception   : yes
            cpuid level     : 1
            wp              : yes
            flags           : lua coroutine table string math
            bogomips        : %d
            clflush size    : 64
            cache_alignment : 64
            address sizes   : 32 bits virtual
            ]], mhz, mhz)
    elseif path == "/proc/uptime" then
        return tostring(_G.os.clock()) .. "\n"
    elseif path == "/proc/meminfo" then
        local mem_total = 4096
        local time_seed = math.floor(_G.os.clock() * 10)
        local mem_used  = 256 + (time_seed % 128)
        local mem_free  = mem_total - mem_used
        return string.format([[
            MemTotal:       %8d kB
            MemFree:        %8d kB
            MemAvailable:   %8d kB
            Buffers:               0 kB
            Cached:              124 kB
            SwapTotal:             0 kB
            SwapFree:              0 kB
            Shmem:                 0 kB
            Slab:                 42 kB
            ]], mem_total, mem_free, mem_free)
    elseif path == "/proc/version" then
        return "Loom Kernel version 4.0.0 (root@omnissiah) (lua-5.1) #1 SMP " .. os.date("%c") .. "\n"
    end

    return nil
end

local function generate_sys_content(path)
    if path == "/sys/class/net/modem0/address" then
        local id = os.getComputerID()
        return string.format("00:1A:2B:3C:%02X:%02X\n", math.floor(id / 256), id % 256)
    end

    return nil
end

function vfs.reload_permissions()
    permissions_cache = nil
end

local function check_permission(uid, virtual_path, requested_perm)
    if uid == 0 then return true end

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

    local available_perms = rule and (uid == rule.owner and (rule.perms or "") or (rule.all or perms_db.all or "r")) or (perms_db.all or "r")

    if string.find(available_perms, requested_perm) then
        return true
    end

    return false, "Permission denied"
end

local function prepare_access(root, cwd, path, uid, req_perm)
    if path == "/dev/null" or path == "/dev/random" or path == "/dev/zero" then
        return true, path, path
    end

    local virtual_path = path:byte(1) == 47 and path or fs.combine(cwd, path)
    virtual_path = "/" .. fs.combine("", virtual_path)
    local real_path = fs.combine(root, fs.combine("", virtual_path))

    local has_perm, err = check_permission(uid, virtual_path, req_perm)
    if not has_perm then return false, err end

    return true, real_path, virtual_path
end

function vfs.get_dir(path)
    if path == "" or path == "/" then return "/" end
    local parent_dir = string.match(path, "^(.*)/[^/]*$")
    if not parent_dir or parent_dir == "" then return "/" end
    return parent_dir
end

function vfs.open(uid, root, cwd, path, mode)
    if path == "/dev/null"   then return true, { type = NODE_TYPE.NULL, mode = mode } end
    if path == "/dev/random" then return true, { type = NODE_TYPE.RAND, mode = "r"  } end
    if path == "/dev/zero"   then return true, { type = NODE_TYPE.ZERO, mode = "r"  } end
    if path:sub(1, 6) == "/proc/" then
        if mode ~= "r" then return false, "Permission denied" end
        if generate_proc_content(path) == nil then return false, "Proc entry not found" end

        return true, {
            type = NODE_TYPE.PROC,
            mode = "r",
            path = path,
        }
    end
    if path:sub(1, 5) == "/sys/" then
        if mode ~= "r" then return false, "Permission denied" end
        if generate_sys_content(path) == nil then return false, "Sys entry not found" end
        return true, {
            type = NODE_TYPE.SYS,
            mode = "r",
            path = path,
        }
    end

    local req_perm = (mode == "r") and "r" or "w"
    local ok, real_path, err = prepare_access(root, cwd, path, uid, req_perm)

    if not ok then return nil, err end

    local handle = fs.open(real_path, mode)

    if not handle then return nil, "Cannot open: " .. path end

    return true, {
        type = NODE_TYPE.FILE,
        mode = mode,
        handle = handle,
        real_path = real_path,
    }
end

function vfs.read(node)
    if not node then return false, "Bad file descriptor" end
    if node.type == NODE_TYPE.FILE then if node.handle.readAll then return true, node.handle.readAll() end
    elseif node.type == NODE_TYPE.PIPE then
        local data = node.buffer.data
        node.buffer.data = ""
        return true, data
    elseif node.type == NODE_TYPE.NULL then return true, nil
    elseif node.type == NODE_TYPE.RAND then return true, krng.read_random_bytes(32)
    elseif node.type == NODE_TYPE.ZERO then return true, 0
    elseif node.type == NODE_TYPE.SOCKET then if #node.buffer > 0 then return true, table.remove(node.buffer, 1) else return false, "EAGAIN" end
    elseif node.type == NODE_TYPE.PROC then return true, generate_proc_content(node.path)
    elseif node.type == NODE_TYPE.SYS then return true, generate_sys_content(node.path) end

    return false, "Unknown node type"
end

function vfs.write(node, data)
    if not node then return false, "Bad file descriptor" end
    if node.mode == "r" then return false, "Node opened for reading only" end

    local text = tostring(data)

    if node.type == NODE_TYPE.FILE then
        node.handle.write(text)
        return true
    elseif node.type == NODE_TYPE.PIPE then
        node.buffer.data = node.buffer.data .. text
        return true
    elseif node.type == NODE_TYPE.NULL then
        return true
    elseif node.type == NODE_TYPE.SOCKET then
        return false, "Use socket API for writing to network nodes"
    end

    return false, "Invalid node type"
end

function vfs.close(node)
    if not node then return false end
    if node.type == NODE_TYPE.FILE and node.handle then
        pcall(function() node.handle.close() end)
        node.handle = nil
    end
    return true
end

function vfs.pipe()
    local pipe_buffer = { data = "" }
    local node_read = { type = NODE_TYPE.PIPE, mode = "r", buffer = pipe_buffer }
    local node_write = { type = NODE_TYPE.PIPE, mode = "w", buffer = pipe_buffer }
    return node_read, node_write
end

function vfs.socket()
    return true, {
        type = NODE_TYPE.SOCKET,
        status = "CLOSED",
        local_port = nil,
        remote_port = nil,
        buffer = {}
    }
end

function vfs.resolve_cwd(root, current_cwd, new_path)
    local virtual_path = new_path:byte(1) == 47 and new_path or fs.combine(current_cwd, new_path)
    virtual_path = "/" .. fs.combine("", virtual_path)
    local real_path = fs.combine(root, fs.combine("", virtual_path))

    if fs.exists(real_path) and fs.isDir(real_path) then
        return true, virtual_path
    end
    return nil, "Not a valid directory"
end

function vfs.exists(uid, root, cwd, path)
    local ok, real_path = prepare_access(root, cwd, path, uid, "r")
    if not ok then return false end
    if real_path == "/dev/null" or real_path == "/dev/random" or real_path == "/dev/zero" then return true end
    return fs.exists(real_path)
end

function vfs.is_dir(uid, root, cwd, path)
    local ok, real_path = prepare_access(root, cwd, path, uid, "r")
    if not ok then return false end
    if real_path == "/dev/null" or real_path == "/dev/random" or real_path == "/dev/zero" then return false end
    return fs.isDir(real_path)
end

function vfs.list(uid, root, cwd, path)
    local ok, real_path = prepare_access(root, cwd, path, uid, "r")
    if not ok then return false, nil end
    if fs.exists(real_path) and fs.isDir(real_path) then return true, fs.list(real_path) end
    return false, nil
end

function vfs.make_dir(uid, root, cwd, path)
    local ok, real_path, err = prepare_access(root, cwd, path, uid, "w")
    if not ok then return false, err end
    if fs.exists(real_path) then return false, "Directory already exists" end

    local success, sys_err = pcall(function() fs.makeDir(real_path) end)
    return success, sys_err or "Unknown error"
end

function vfs.move(uid, root, cwd, path_init, path_dest)
    local ok_init, real_path_init, err_init = prepare_access(root, cwd, path_init, uid, "r")
    if not ok_init then return false, err_init end

    local ok_dest, real_path_dest, err_dest = prepare_access(root, cwd, path_dest, uid, "w")
    if not ok_dest then return false, err_dest end

    if not fs.exists(real_path_init) then return false, "Source does not exist" end
    if fs.exists(real_path_dest) then return false, "Destination already exists" end

    fs.move(real_path_init, real_path_dest)
    return true
end

function vfs.delete(uid, root, cwd, path)
    local ok, real_path, err = prepare_access(root, cwd, path, uid, "w")
    if not ok then return false, err end
    if not fs.exists(real_path) then return false, "File or directory does not exist" end

    local success, sys_err = pcall(function () fs.delete(real_path) end)
    return success, sys_err or "Unknown error"
end

function vfs.get_capacity(uid, root, cwd, path)
    local ok, real_path = prepare_access(root, cwd, path, uid, "r")
    if not ok or not fs.exists(real_path) then return false, "File or directory does not exist" end
    return fs.getCapacity(real_path)
end

function vfs.get_free_space(uid, root, cwd, path)
    local ok, real_path = prepare_access(root, cwd, path, uid, "r")
    if not ok or not fs.exists(real_path) then return false, "File or directory does not exist" end
    return fs.getFreeSpace(real_path)
end

function vfs.get_file_attributes(virtual_path)
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

    local owner = rule and rule.owner or 0
    local perms = rule and rule.perms or (perms_db.all or "r")

    local is_suid = string.find(perms, "s") ~= nil

    return owner, perms, is_suid
end

return vfs