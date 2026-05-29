local config = require("iDar.opt.Loom.config")
local vfs = require("iDar.opt.Loom.vfs")
local krng = require("iDar.opt.Loom.krng")
local min_heap = require("iDar.opt.Loom.structs.heap.init")

local scheduler = {
    processes = {},
    incoming_processes = {},
    current_process = nil,
    active_thread_meta = nil
}

local function compare_vruntime(a, b)
    return (a.vruntime or 0) < (b.vruntime or 0)
end

function scheduler.join_party(new_process)
    new_process.superrr = new_process.superrr or 0

    for _, thread in ipairs(new_process.threads) do
        thread.vruntime = thread.vruntime or 0
        thread.superrr = new_process.superrr
        thread.parent_process = new_process
    end

    table.insert(scheduler.incoming_processes, new_process)
end

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
    local last_event_time = os.clock()

    while true do
        while #scheduler.incoming_processes > 0 do
            table.insert(scheduler.processes, table.remove(scheduler.incoming_processes, 1))
        end

        if #scheduler.processes == 0 then break end

        local event_data = {}

        if needs_cpu and not initial_start then
            os.startTimer(0)
        end

        if not initial_start then
            event_data = table.pack(os.pullEventRaw())
        end

        if event_data and event_data[1] then
            local now = os.clock()
            local inter_event_jitter = tostring(math.floor((now - last_event_time) * 1e9))
            last_event_time = now
            local garbage_parts = {}

            if event_data[1] == "modem_message" then
                local channel = event_data[3]
                local raw_packet = event_data[5]

                if type(raw_packet) == "table" and raw_packet.sender_id then
                    vfs.route_network_packet(raw_packet.sender_id, channel, raw_packet.payload)
                end
            end

            for i = 1, event_data.n do
                table.insert(garbage_parts, tostring(event_data[i]))
            end
            local garbage = table.concat(garbage_parts, ":") .. ":" .. tostring(now) .. ":" .. inter_event_jitter
            krng.add_entropy(garbage)
        end

        initial_start = false
        needs_cpu = false

        local ready_queue = min_heap.new_min({}, compare_vruntime)

        for p = 1, #scheduler.processes do
            local process = scheduler.processes[p]

            for t = 1, #process.threads do
                local active_meta = process.threads[t]
                local should_resume = true

                if active_meta.filter and active_meta.filter ~= event_data[1] then
                    if event_data[1] ~= "terminate" then
                        should_resume = false
                    end
                end

                if should_resume then
                    ready_queue:insert(active_meta)
                end
            end
        end

        while #ready_queue.nodes > 0 do
            local active_meta = ready_queue:pop()
            local process = active_meta.parent_process

            scheduler.current_process = process
            scheduler.active_thread_meta = active_meta

            local clock_start = os.clock()
            active_meta.start_time = os.epoch("utc")
            active_meta.forced_yield = false

            local ok, yielded_val = coroutine.resume(
                active_meta.co,
                table.unpack(event_data, 1, event_data.n or #event_data)
            )

            local clock_end = os.clock()
            local delta_time = clock_end - clock_start

            local weight = 1.025 ^ (active_meta.superrr or 0)
            active_meta.vruntime = (active_meta.vruntime or 0) + (delta_time * weight)

            if ok and not active_meta.forced_yield then
                active_meta.time_limit = config.base_time
            end

            if not ok then
                print("Error in " .. process.name .. ": " .. tostring(yielded_val))
            else
                if active_meta.forced_yield then
                    active_meta.filter = nil
                    needs_cpu = true
                else
                    active_meta.filter = yielded_val
                end
            end

            scheduler.current_process = nil
            scheduler.active_thread_meta = nil
        end

        for p = #scheduler.processes, 1, -1 do
            local process = scheduler.processes[p]

            for t = #process.threads, 1, -1 do
                if coroutine.status(process.threads[t].co) == "dead" then
                    table.remove(process.threads, t)
                end
            end

            if #process.threads == 0 then
                vfs.cleanup_process(process.pid)
                os.queueEvent("process_dead", process.pid)
                table.remove(scheduler.processes, p)
            end
        end
    end
end

return scheduler