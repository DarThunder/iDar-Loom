local config = require("..iDar.Loom.src.config")

local scheduler = {
    processes = {},
    current_process = nil,
    active_thread_meta = nil
}

function scheduler.force_round_robin()
    if not scheduler.active_thread_meta then return end

    local elapsed = os.epoch("utc") - scheduler.active_thread_meta.start_time

    if elapsed > scheduler.active_thread_meta.time_limit then
        scheduler.active_thread_meta.time_limit = math.min(
            config.max_time, 
            scheduler.active_thread_meta.time_limit + config.extension_time
        )
        scheduler.active_thread_meta.forced_yield = true
        coroutine.yield()
    end
end

function scheduler.execute()
    local initial_start = true
    local needs_cpu = true

    while #scheduler.processes > 0 do
        local event_data = {}

        if needs_cpu and not initial_start then
            os.startTimer(0)
        end

        if not initial_start then
            event_data = table.pack(os.pullEventRaw())
        end

        initial_start = false
        needs_cpu = false

        local p = 1
        while p <= #scheduler.processes do
            local process = scheduler.processes[p]
            scheduler.current_process = process

            local t = 1
            while t <= #process.threads do
                scheduler.active_thread_meta = process.threads[t]
                local active_meta = scheduler.active_thread_meta
                local should_resume = true
                
                if active_meta.filter and active_meta.filter ~= event_data[1] then
                    if event_data[1] ~= "terminate" then
                        should_resume = false
                    end
                end

                if should_resume then
                    active_meta.start_time = os.epoch("utc")
                    active_meta.forced_yield = false
                    local ok, yielded_val = coroutine.resume(
                        active_meta.co, 
                        table.unpack(event_data, 1, event_data.n or #event_data)
                    )

                    if ok and not active_meta.forced_yield then
                        active_meta.time_limit = config.base_time
                    end

                    if not ok then
                        print("Error in " .. process.name .. ": " .. tostring(yielded_val))
                        table.remove(process.threads, t)
                        t = t - 1
                    elseif coroutine.status(active_meta.co) == "dead" then
                        table.remove(process.threads, t)
                        t = t - 1
                    else
                        if active_meta.forced_yield then
                            active_meta.filter = nil
                            needs_cpu = true
                        else
                            active_meta.filter = yielded_val 
                        end
                    end
                end

                t = t + 1
            end

            scheduler.current_process = nil
            scheduler.active_thread_meta = nil

            if #process.threads == 0 then
                os.queueEvent("process_dead", process.pid)
                table.remove(scheduler.processes, p)
            else
                p = p + 1
            end
        end
    end
end

return scheduler