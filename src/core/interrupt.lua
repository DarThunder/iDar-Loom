local kstate = require("iDar.boot.Loom.core.kstate")

local interrupt = {}

function interrupt.force_yield()
    local victim = kstate.current

    if not victim then return end

    local elapsed = os.epoch("utc") - victim.start_time

    if elapsed >= victim.quantum then
        coroutine.yield("_KERNEL_PREEMPT_SIGNAL") --proceso machucar pilin de scheduler
    end
end

return interrupt