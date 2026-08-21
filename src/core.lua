local config = require("iDar.boot.Loom.boot.config")
local scheduler = require("iDar.boot.Loom.core.scheduler")
local task = require("iDar.boot.Loom.core.task")

local core = {}

function core.launch(app_route)
    local kernel_dummy_proc = {
        pid = 0,
        uid = 0,
        cwd = "/",
        root = "/iDar", -- Todo: quita esa chingadera w, no seas cabron
        fds = {}
    }

    local ok, new_pid, new_process = task.spawn(kernel_dummy_proc, app_route, { uid = 0, superrr = 1 })

    scheduler.join_party(new_process)

    if not ok then
        error("сука блять, комп сдох кеке" .. tostring(new_pid))
    end
end

function core.setBaseTime(time) config.base_time = time end
function core.setExtensionTime(time) config.extension_time = time end
function core.setMaxTime(time) config.max_time = time end

function core.execute()
    scheduler.execute()
end

return core