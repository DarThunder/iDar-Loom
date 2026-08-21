local config = require("iDar.boot.Loom.boot.config")
local kstate = require("iDar.boot.Loom.core.kstate")
local krng   = require("iDar.boot.Loom.sec.krng")
local vfs    = require("iDar.boot.Loom.fs.vfs")
local min_heap = require("iDar.boot.Loom.structs.heap.init")
local ksyscalls = require("iDar.boot.Loom.core.ksyscalls")
local tty_driver = require("iDar.boot.Loom.drivers.tty")
local net_driver = require("iDar.boot.Loom.drivers.net")

net_driver.init() -- aaa no mames es el linus ola linus
tty_driver.init() -- hola soy linus

local ksig = {
    BLOCK = 0xA0,
    SPAWN = 0xA1,
    EXIT  = 0xA2
}

local scheduler = {
    ready_queue = min_heap.new_min({}, function(a, b) return (a.vruntime or 0) < (b.vruntime or 0) end),
    wait_queue = {},
    global_weight = 0
}

function scheduler.join_party(new_process)
    new_process.superrr = new_process.superrr or 0
    new_process.vruntime = new_process.vruntime or 0
    new_process.weight = new_process.weight ~= 0 and new_process.weight or 1.025 ^ (new_process.superrr or 0) or new_process.weight
    scheduler.global_weight = scheduler.global_weight + new_process.weight
    scheduler.ready_queue:insert(new_process)
    kstate.process_table[new_process.pid] = new_process
end

local function kernel_maid()
    local dead = {}

    for _, process in pairs(kstate.process_table) do
        if coroutine.status(process.co) == "dead" or process.killed then
            dead[#dead+1] = process
        end
    end
    for _, process in ipairs(dead) do
        if process.fds then
            for fd, node in pairs(process.fds) do
                if fd > 2 then
                    if node.type == "socket" then
                        net_driver.close(node)
                    else
                        vfs.close(node)
                    end
                end
            end
        end
        for key, proc in pairs(scheduler.wait_queue) do
            if proc.pid == process.pid then
                scheduler.wait_queue[key] = nil
            end
        end

        tty_driver.cleanup_process(process.pid)
        os.queueEvent("process_dead", process.pid)

        scheduler.ready_queue:remove(process)
        kstate.process_table[process.pid] = nil
    end
end

local function kernel_secretary(last_event_time)
    local process = nil

    if #scheduler.ready_queue.nodes > 0 then
        os.queueEvent("kernel_yield")
    end

    local event_data = table.pack(os.pullEventRaw())

    if event_data[1] == "kernel_yield" then
        return os.clock()
    end

    if event_data and event_data[1] then
        local now = os.clock()
        local inter_event_jitter = tostring(math.floor((now - last_event_time) * 1e9))
        last_event_time = now
        local event = event_data[1]

        if event == "char" or event == "key" or event == "key_up" then
            local wake_pid = tty_driver.handle_hardware_input(event, table.unpack(event_data, 2, event_data.n))

            if wake_pid then
                process = scheduler.wait_queue["tty_wait_" .. wake_pid]
                if process then
                    scheduler.wait_queue["tty_wait_" .. wake_pid] = nil
                    local _, data = tty_driver.read(wake_pid)
                    process.pending_process = {data}
                end
            end
        elseif event == "modem_message" then
            local local_port = event_data[3]
            local reply_port = event_data[4]
            local raw_packet = event_data[5]

            local wake_pid = net_driver.handle_modem_message(local_port, reply_port, raw_packet)
            if wake_pid then
                process = scheduler.wait_queue["net_wait_" .. wake_pid]
                if process then
                    scheduler.wait_queue["net_wait_" .. wake_pid] = nil
                    process.pending_process = {}
                end
            end
        elseif event == "timer" then
            process = scheduler.wait_queue["timer_" .. event_data[2]]
            scheduler.wait_queue["timer_" .. event_data[2]] = nil
        elseif event == "process_dead" then
            process = scheduler.wait_queue["wait_" .. event_data[2]]
            scheduler.wait_queue["wait_" .. event_data[2]] = nil
            if process then
                process.pending_process = {event_data[2]}
            end
        end

        if process then
            local min_vruntime = scheduler.ready_queue.nodes[1] and scheduler.ready_queue.nodes[1].vruntime or 0
            local wakeup_bonus = config.target_latency / 2
            process.vruntime = math.max(0, min_vruntime - wakeup_bonus)

            scheduler.ready_queue:insert(process)
        end

        local parts = {event_data[1]}
        for i = 2, event_data.n do parts[i] = tostring(event_data[i]) end
        parts[#parts+1] = tostring(now)
        parts[#parts+1] = inter_event_jitter

        krng.add_entropy(table.concat(parts, ":"))
    end

    return last_event_time
end

local function kernel_butler()
    local insert_process = {}

    while #scheduler.ready_queue.nodes > 0 do
        local process = scheduler.ready_queue:pop()
        scheduler.global_weight = scheduler.global_weight - process.weight

        local arg_count = process.pending_process.n or #process.pending_process
        local clock_start = os.clock()
        local calculated_slice = config.target_latency * (process.weight / scheduler.global_weight)
        process.quantum = math.max(config.min_granularity, calculated_slice)
        kstate.current = process
        process.start_time = os.epoch("utc")

        local ok, yielded_val = coroutine.resume(process.co, table.unpack(process.pending_process, 1, arg_count))

        local clock_end = os.clock()
        local delta_time = clock_end - clock_start
        process.weight = 1.025 ^ (process.superrr or 0)
        process.vruntime = (process.vruntime or 0) + (delta_time * process.weight)

        process.pending_process = {}

        if not ok then
            local err_msg = "\n[SIGSEGV] Fatal error in PID " .. process.pid .. " (" .. process.name .. "):\n" .. tostring(yielded_val) .. "\n"
            tty_driver.write(process.pid, err_msg, true)
            process.killed = true
            scheduler.global_weight = scheduler.global_weight - process.weight
        else
            if type(yielded_val) == "table" then
                if yielded_val[1] == 0x01 then
                    local syscall_id = yielded_val[2]
                    local result = table.pack(ksyscalls.dispatch(process, syscall_id, table.unpack(yielded_val, 3)))

                    if result[1] == ksig.BLOCK then
                        scheduler.wait_queue[result[2]] = process
                    elseif result[1] == ksig.SPAWN then
                        scheduler.join_party(result[3])
                        process.pending_process = {result[2]}
                        table.insert(insert_process, process)
                        scheduler.global_weight = scheduler.global_weight + process.weight
                    elseif result[1] == ksig.EXIT then
                    else
                        process.pending_process = result
                        table.insert(insert_process, process)
                        scheduler.global_weight = scheduler.global_weight + process.weight
                    end
                elseif yielded_val[1] == 0x02 then
                    scheduler.wait_queue[yielded_val[2] .. "_" .. process.pid] = process
                elseif yielded_val[1] == 0x03 then
                    local time = yielded_val[2] or 0.05
                    local timer_id = os.startTimer(time)
                    scheduler.wait_queue["timer_" .. timer_id] = process
                end
            else
                table.insert(insert_process, process)
                scheduler.global_weight = scheduler.global_weight + process.weight
            end
        end
    end

    for _, process in ipairs(insert_process) do
        scheduler.ready_queue:insert(process)
    end
end

function scheduler.execute()
    local last_event_time = os.clock()

    while true do
        kernel_maid()
        last_event_time = kernel_secretary(last_event_time)
        kernel_butler()
    end
end

return scheduler