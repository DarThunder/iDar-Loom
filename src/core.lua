local config = require("..iDar.Loom.src.config")
local scheduler = require("..iDar.Loom.src.scheduler")
local sandbox = require("..iDar.Loom.src.sandbox")

local core = {}
local next_pid = 1

function core.setBaseTime(time) config.base_time = time end
function core.setExtensionTime(time) config.extension_time = time end
function core.setMaxTime(time) config.max_time = time end

function core.launch(app_route, options, ...)
    local file = io.open(app_route, "r")
    if not file then error("Can't open: " .. tostring(app_route)) end
    local content = file:read("*a")
    file:close()

    local syscalls = {
        launch = function(path, options, ...)
            return core.launch(path, options, ...)
        end
    }

    local env = sandbox.create(syscalls, options and options.term or nil)
    local func, err = load(content, app_route, "t", env)
    if not func then error("Error: " .. tostring(err)) end

    local args = {...}

    local function wrapper()
        func(table.unpack(args))
    end

    local main_co = coroutine.create(wrapper)
    debug.sethook(main_co, scheduler.force_round_robin, "", config.hook_instructions)

    local pid = next_pid
    next_pid = next_pid + 1

    local new_process = {
        pid = pid,
        name = app_route,
        threads = {
            {
                co = main_co,
                time_limit = config.base_time,
                start_time = 0,
                forced_yield = false
            }
        }
    }
    table.insert(scheduler.processes, new_process)

    return pid
end

function core.execute()
    scheduler.execute()
end

return core