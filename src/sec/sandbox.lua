local sandbox = {}
local shared_lib_cache = {}

local function secure_copy(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
end

local NATIVE_LIBS = {
    math = math,
    string = string,
    table = table,
    bit32 = bit32,
    colors = colors,
    keys = keys,
    textutils = textutils
}

function sandbox.create(custom_term, pid)
    local env = {
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        error = error,
        assert = assert,
        pcall = pcall,
        xpcall = xpcall,
        pairs = pairs,
        ipairs = ipairs,
        next = next,
        table = {
            insert = table.insert,
            remove = table.remove,
            unpack = table.unpack,
            concat = table.concat,
            pack = table.pack,
            sort = table.sort,
        },
        coroutine = {
            yield = coroutine.yield
        },
        package = {
            loaded = {},
            path = "/lib/?.lua;/?/init.lua;/?.lua"
        }
    }

    env.setmetatable = function(t, mt)
        if type(t) ~= "table" then
            error("bad argument #1 to 'setmetatable' (table expected)")
        end

        if t == env or t == env.package or t == env.package.loaded or t == env.coroutine or t == env.table then
            error("Kernel Security: Permission denied to modify system table metatables")
        end

        return setmetatable(t, mt)
    end

    env.require = function(modname)
        if env.package.loaded[modname] ~= nil then
            return env.package.loaded[modname]
        end

        if modname == "term" then
            env.package.loaded[modname] = custom_term
            return custom_term
        end

        if NATIVE_LIBS[modname] then
            local lib_copy = secure_copy(NATIVE_LIBS[modname])
            env.package.loaded[modname] = lib_copy
            return lib_copy
        end

        local is_shared_lib = not modname:match("^opt%.")
        local modpath = modname:gsub("%.", "/")
        local content = nil
        local found_path = nil

        if is_shared_lib and shared_lib_cache[modname] ~= nil then
            content = shared_lib_cache[modname].content
            found_path = shared_lib_cache[modname].path
        else
            for pattern in string.gmatch(env.package.path, "([^;]+)") do
                local try_path = pattern:gsub("?", modpath)
                local fd = coroutine.yield({0x01, 0x02, try_path, "r"})

                if fd > 0 then
                    content = coroutine.yield({0x01, 0x00, fd})
                    coroutine.yield({0x01, 0x03, fd})
                    found_path = try_path
                    break
                end
            end

            if not content then
                error("module '" .. modname .. "' not found. Checked: " .. env.package.path)
            end

            if is_shared_lib then
                shared_lib_cache[modname] = { content = content, path = found_path }
            end
        end

        local func = load(content, found_path, "t", env)
        if not func then
            error("Error compiling module '" .. modname .. "': " .. content)
        end

        local result = func()
        if result == nil then
            result = true
        end

        env.package.loaded[modname] = result

        return result
    end

    env.load = function(chunk, chunkname, mode, loadenv)
        return load(chunk, chunkname or "=(load)", mode or "t", loadenv or env)
    end

    return env
end

return sandbox
