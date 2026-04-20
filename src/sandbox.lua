local config = require("..iDar.Loom.src.config")
local scheduler = require("..iDar.Loom.src.scheduler")

local sandbox = {}

function sandbox.create(syscalls, custom_term)
    local env = {
        os = os,
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
        require = require,
        package = package,
        print = print,
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
        load = load
    }

    setmetatable(env, { __index = _G })

    env.sys = {
        spawn = function(app_route, options, ...)
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
        end
    }

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

    env.term = custom_term or term

    return env
end

return sandbox