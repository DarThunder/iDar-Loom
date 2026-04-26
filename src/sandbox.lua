local config = require("iDar.opt.Loom.config")
local scheduler = require("iDar.opt.Loom.scheduler")

local sandbox = {}
local shared_lib_cache = {}

function sandbox.create(syscalls, custom_term, pid)
    local env = {
        os = os,
        textutils = textutils,
        sleep = function(time)
            local t = tonumber(time) or 0
            local timerID = _G.os.startTimer(t)
            while true do
                local event = table.pack(coroutine.yield("timer"))
                if event[1] == "timer" and event[2] == timerID then
                    break
                end
            end
        end,
        math = math,
        string = string,
        table = table,
        tostring = tostring,
        tonumber = tonumber,
        ipairs = ipairs,
        pairs = pairs,
        type = type,
        next = next,
        error = error,
        assert = assert,
        pcall = pcall,
        xpcall = xpcall,
        load = load,
        iDarBoot = iDarBoot,
        colors = colors,
        keys = keys,
        setmetatable = setmetatable,
        peripheral = peripheral,
        http = http,
        bit32 = bit32,
        bit = bit,

    }

    local function load_packages()
        local f = io.open("iDar/var/local.lua", "r")
        if not f then return {} end
        local content = f:read("*a")
        f:close()

        local chunk, err = load(content, "local.lua", "t", {})
        if not chunk then return {} end
        return chunk() or {}
    end

    local packages = load_packages()

    env._OS = {
        name = "iDar-OS",
        Kernel = {
            name = "Loom",
            ver = "Alpha 1.1",
        },
        Shell = {
            name = "DSH",
            ver = "Alpha 1.1",
        },
        Packages = {}
    }

    for pkg_name, pkg_data in pairs(packages) do
        table.insert(env._OS.Packages, {name = pkg_name, ver = pkg_data.installed_version})
    end

    --idk why i put this, but the ways of God are mysterious
    --setmetatable(env, { __index = _G })

    local vfs_syscalls = require("iDar.opt.Loom.vfs").create_syscalls(pid)

    env.sys = {
        spawn = function(app_route, options, ...)
            options = options or {}
            options.parent_pid = pid

            if syscalls and syscalls.launch then
                return syscalls.launch(app_route, options, ...)
            else
                error("No system call interface available")
            end
        end,
        wait = function(pid)
            while true do
                local event_data = table.pack(coroutine.yield("process_dead"))
                local event = event_data[1]
                local dead_pid = event_data[2]

                if event == "process_dead" and dead_pid == pid then
                    break
                end
            end
        end,
        get_pid = function()
            return pid
        end,
        set_foreground = function(target_pid)
            _G.os.queueEvent("set_foreground", target_pid)
        end,
        pull_input = function()
            while true do
                local event_data = table.pack(coroutine.yield())
                local event_name = event_data[1]
                
                if event_name == "fg_char_" .. pid then
                    return "char", event_data[2]
                elseif event_name == "fg_key_" .. pid then
                    return "key", event_data[2], event_data[3]
                elseif event_name == "fg_key_up_" .. pid then
                    return "key_up", event_data[2]
                end
            end
        end,
        open = vfs_syscalls.open,
        write = vfs_syscalls.write,
        read = vfs_syscalls.read,
        close = vfs_syscalls.close,
        pipe = vfs_syscalls.pipe,
        exists = vfs_syscalls.exists,
        is_dir = vfs_syscalls.is_dir,
        list = vfs_syscalls.list,
        read_line = vfs_syscalls.read_line,
        lines = function(fd)
            return function()
                return vfs_syscalls.read_line(fd)
            end
        end,
        mkdir = vfs_syscalls.mkdir,
        get_dir = vfs_syscalls.get_dir,
        move = vfs_syscalls.move,
        delete = vfs_syscalls.delete,
        dofile = vfs_syscalls.dofile,
        get_capacity = vfs_syscalls.get_capacity,
        get_free_space = vfs_syscalls.get_free_space,
        get_cwd = vfs_syscalls.get_cwd,
        set_cwd = vfs_syscalls.set_cwd,
        combine = _G.fs.combine,
    }

    env.fs = nil
    env.io = nil

    env.coroutine = {
        create = function(f)
            local co = coroutine.create(f)
            debug.sethook(co, scheduler.force_round_robin, "", config.hook_instructions)
            local thread_meta = {
                co = co,
                time_limit = config.base_time,
                start_time = 0,
                forced_yield = false
            }

            if scheduler.current_process then
                table.insert(scheduler.current_process.threads, thread_meta)
            end

            return co
        end,
        yield = function(...) return coroutine.yield(...) end,
        resume = function(co, ...) return coroutine.resume(co, ...) end,
        status = coroutine.status
    }

    env.parallel = {
        waitForAll = function(...)
            local funcs = {...}
            local threads = {}
            for _, f in ipairs(funcs) do
                table.insert(threads, env.coroutine.create(f))
            end
            while true do
                local all_dead = true
                for _, co in ipairs(threads) do
                    if env.coroutine.status(co) ~= "dead" then
                        all_dead = false
                        break
                    end
                end
                if all_dead then break end
                coroutine.yield()
            end
        end,

        waitForAny = function(...)
            local funcs = {...}
            local threads = {}
            for _, f in ipairs(funcs) do
                table.insert(threads, env.coroutine.create(f))
            end
            while true do
                for _, co in ipairs(threads) do
                    if env.coroutine.status(co) == "dead" then
                        return
                    end
                end
                coroutine.yield()
            end
        end
    }

    env.package = {
        loaded = {},
        path = "/lib/?.lua;/?/init.lua;/?.lua"
    }

    env.require = function(modname)
        local is_shared_lib = not modname:match("^opt%.")

        if is_shared_lib and shared_lib_cache[modname] ~= nil then
            return shared_lib_cache[modname]
        end

        if env.package.loaded[modname] ~= nil then
            return env.package.loaded[modname]
        end

        local modpath = modname:gsub("%.", "/")
        local content = nil
        local found_path = nil

        for pattern in string.gmatch(env.package.path, "([^;]+)") do
            local try_path = pattern:gsub("?", modpath)

            local fd = vfs_syscalls.open(try_path, "r")
            if fd then
                content = vfs_syscalls.read(fd)
                vfs_syscalls.close(fd)
                found_path = try_path
                break
            end
        end

        if not content then
            error("module '" .. modname .. "' not found in iDar VFS")
        end

        local func, compile_err = load(content, found_path, "t", env)
        if not func then
            error("Error compiling module '" .. modname .. "': " .. tostring(compile_err))
        end

        local result = func()
        if result == nil then
            result = true
        end

        if is_shared_lib then
            shared_lib_cache[modname] = result
        else
            env.package.loaded[modname] = result
        end

        return result
    end

    env.print = function(...)
        local args = table.pack(...)
        local output = {}

        for i = 1, args.n do
            table.insert(output, tostring(args[i]))
        end

        local final_string = table.concat(output, "\t") .. "\n"

        env.sys.write(1, final_string)
    end

    env.read = function(prompt_text, prompt_color, history_table, completion_fn)
        completion_fn = completion_fn or function(_) end
        local input = ""
        local cursor_pos = 1
        local ctrl_held = false
        local history_index = #history_table + 1
        local draft_input = ""
        local start_x, start_y = term.getCursorPos()
        local max_length_drawn = 0

        local function redraw()
            local w, h = term.getSize()

            term.setCursorPos(start_x, start_y)

            local text_to_draw = prompt_text .. input
            local current_length = #text_to_draw

            term.setTextColor(prompt_color or colors.yellow)
            env.sys.write(1, prompt_text)
            term.setTextColor(colors.white)
            env.sys.write(1, input)

            if current_length < max_length_drawn then
                for i = current_length, max_length_drawn - 1 do
                    local ghost_index = (start_x - 1) + i
                    local gx = (ghost_index % w) + 1
                    local gy = start_y + math.floor(ghost_index / w)

                    term.setCursorPos(gx, gy)
                    term.write(" ")
                end
            else
                max_length_drawn = current_length
            end

            local linear_index = (start_x - 1) + #prompt_text + (cursor_pos - 1)
            local target_x = (linear_index % w) + 1
            local target_y = start_y + math.floor(linear_index / w)

            term.setCursorPos(target_x, target_y)
            term.setCursorBlink(true)
        end

        redraw()

        while true do
            local event, param = env.sys.pull_input()
            local needs_draw = false

            if event == "key" then
                if param == keys.leftCtrl or param == keys.rightCtrl then
                    ctrl_held = true

                elseif param == keys.l and ctrl_held then
                    term.clear()
                    term.setCursorPos(1, 1)
                    start_x, start_y = 1, 1
                    max_length_drawn = 0
                    needs_draw = true

                elseif param == keys.d and ctrl_held then
                    term.setCursorBlink(false)
                    return "exit"

                elseif param == keys.a and ctrl_held then
                    cursor_pos = 1
                    needs_draw = true

                elseif param == keys.e and ctrl_held then
                    cursor_pos = #input + 1
                    needs_draw = true

                elseif param == keys.k and ctrl_held then
                    input = input:sub(1, cursor_pos - 1)
                    needs_draw = true

                elseif param == keys.left then
                    if cursor_pos > 1 then
                        cursor_pos = cursor_pos - 1
                        needs_draw = true
                    end

                elseif param == keys.right then
                    if cursor_pos <= #input then
                        cursor_pos = cursor_pos + 1
                        needs_draw = true
                    end

                elseif param == keys.backspace then
                    if cursor_pos > 1 then
                        input = input:sub(1, cursor_pos - 2) .. input:sub(cursor_pos)
                        cursor_pos = cursor_pos - 1
                        needs_draw = true
                    end

                elseif param == keys.tab then
                    if completion_fn then
                        local text_before_cursor = input:sub(1, cursor_pos - 1)

                        local matches, partial, common = completion_fn(text_before_cursor)

                        if matches then
                            if #matches == 1 then
                                local completion = matches[1]
                                input = input:sub(1, cursor_pos - 1) .. completion .. input:sub(cursor_pos)
                                cursor_pos = cursor_pos + #completion
                                needs_draw = true

                            elseif #matches > 1 then
                                if common and #common > 0 then
                                    input = input:sub(1, cursor_pos - 1) .. common .. input:sub(cursor_pos)
                                    cursor_pos = cursor_pos + #common
                                    needs_draw = true
                                else
                                    print()
                                    local full_matches = {}
                                    for _, m in ipairs(matches) do
                                        table.insert(full_matches, partial .. m:gsub("%s$", ""))
                                    end

                                    local old_color = term.getTextColor()
                                    term.setTextColor(colors.cyan)
                                    print(table.concat(full_matches, "   "))
                                    term.setTextColor(old_color)

                                    needs_draw = true
                                end
                            end
                        end
                    end

                elseif param == keys.enter or param == keys.numPadEnter then
                    term.setCursorBlink(false)
                    print()
                    return input

                elseif param == keys.up then
                    if history_index > 1 then
                        if history_index == #history_table + 1 then
                            draft_input = input
                        end
                        history_index = history_index - 1
                        input = history_table[history_index]
                        cursor_pos = #input + 1
                        needs_draw = true
                    end

                elseif param == keys.down then
                    if history_index < #history_table then
                        history_index = history_index + 1
                        input = history_table[history_index]
                        cursor_pos = #input + 1
                        needs_draw = true
                    elseif history_index == #history_table then
                        history_index = history_index + 1
                        input = draft_input
                        cursor_pos = #input + 1
                        needs_draw = true
                    end

                end

            elseif event == "char" then
                input = input:sub(1, cursor_pos - 1) .. param .. input:sub(cursor_pos)
                cursor_pos = cursor_pos + 1
                needs_draw = true

            elseif event == "key_up" then
                if param == keys.leftCtrl or param == keys.rightCtrl then
                    ctrl_held = false
                end
            end

            if needs_draw then
                redraw()
            end
        end
    end

    env.term = custom_term or term

    return env
end

return sandbox