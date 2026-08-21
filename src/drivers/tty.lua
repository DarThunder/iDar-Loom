local tty = {}

local consoles = {}
local active_console_id = 1
local ignore_next_char = false
local pid_to_console = {}

local ansi_colors = {
    [30] = colors.black,   [31] = colors.red,     [32] = colors.green,
    [33] = colors.yellow,  [34] = colors.blue,    [35] = colors.magenta,
    [36] = colors.cyan,    [37] = colors.white,
    [40] = colors.black,   [41] = colors.red,     [42] = colors.green,
    [43] = colors.yellow,  [44] = colors.blue,    [45] = colors.magenta,
    [46] = colors.cyan,    [47] = colors.white,
}

local ctrl_held = false

local tty_keys = {
    [keys.one] = 1, [keys.two] = 2, [keys.three] = 3,
    [keys.four] = 4, [keys.five] = 5, [keys.six] = 6
}

function tty.init()
    local w, h = term.getSize()
    for i = 1, 6 do
        local is_visible = (i == 1)
        consoles[i] = {
            id = i,
            win = window.create(term.current(), 1, 1, w, h, is_visible),
            input_buffer = {},
            waiting_pid = nil
        }
    end
end

function tty.assign_process(pid, console_id)
    console_id = console_id or active_console_id

    if consoles[console_id] then
        pid_to_console[pid] = console_id
        return true
    end
    return false, "Console not found"
end

function tty.cleanup_process(pid)
    pid_to_console[pid] = nil
end

function tty.switch(console_id)
    if not consoles[console_id] or active_console_id == console_id then return end

    consoles[active_console_id].win.setVisible(false)

    active_console_id = console_id
    consoles[active_console_id].win.setVisible(true)

    consoles[active_console_id].win.restoreCursor()
end

function tty.handle_hardware_input(event, ...)
    local param1 = (...)

    if event == "key" and (param1 == keys.leftCtrl or param1 == keys.rightCtrl) then
        ctrl_held = true
    elseif event == "key_up" and (param1 == keys.leftCtrl or param1 == keys.rightCtrl) then
        ctrl_held = false
    end

    if event == "key" and ctrl_held and type(param1) == "number" and tty_keys[param1] then
        tty.switch(tty_keys[param1])
        ignore_next_char = true
        return nil
    end

    if ignore_next_char then
        if event == "char" then
            ignore_next_char = false
            return nil
        elseif event ~= "key_up" then
            ignore_next_char = false
        end
    end

    local active_console = consoles[active_console_id]

    table.insert(active_console.input_buffer, {event, ...})

    if active_console.waiting_pid then
        local wake_pid = active_console.waiting_pid
        active_console.waiting_pid = nil
        return wake_pid
    end

    return nil
end

function tty.read(pid)
    local console_id = pid_to_console[pid]
    if not console_id then return false, "No TTY attached" end

    local console = consoles[console_id]

    if #console.input_buffer > 0 then
        local data = table.remove(console.input_buffer, 1)
        return true, data
    else
        console.waiting_pid = pid
        return true, "BLOCK"
    end
end

function tty.write(pid, text, is_error)
    text = tostring(text)
    local console_id = pid_to_console[pid]
    if not console_id then return false, "No TTY attached" end

    local target_win = consoles[console_id].win

    if is_error then
        local old_color = target_win.getTextColor()
        target_win.setTextColor(colors.red)
        tty.raw_write(target_win, text)
        target_win.setTextColor(old_color)
    else
        tty.raw_write(target_win, text)
    end

    return true
end

function tty.raw_write(target_term, text)
    text = tostring(text)
    local pos = 1
    local w, h = target_term.getSize()

    local function write_chunk(chunk)
        local start = 1
        while start <= #chunk do
            local cx, cy = target_term.getCursorPos()
            local space_left = w - cx + 1

            local chunk_end = start + space_left - 1
            if chunk_end >= #chunk then
                target_term.write(chunk:sub(start))
                break
            else
                local last_space = nil
                for i = chunk_end, start, -1 do
                    if chunk:byte(i) == 32 then
                        last_space = i
                        break
                    end
                end

                if last_space then
                    target_term.write(chunk:sub(start, last_space - 1))
                    start = last_space + 1
                else
                    target_term.write(chunk:sub(start, chunk_end))
                    start = chunk_end + 1
                end

                if cy >= h then
                    target_term.scroll(1)
                    target_term.setCursorPos(1, h)
                else
                    target_term.setCursorPos(1, cy + 1)
                end
            end
        end
    end

    while pos <= #text do
        local esc_start, esc_end, params, command = text:find("\27%[([%d;]*)([a-zA-Z])", pos)
        local nl_start, nl_end = text:find("\n", pos)
        local cr_start, cr_end = text:find("\r", pos)

        local next_event_start = #text + 1
        local event_type = "none"

        if esc_start and esc_start < next_event_start then
            next_event_start = esc_start
            event_type = "escape"
        end
        if nl_start and nl_start < next_event_start then
            next_event_start = nl_start
            event_type = "newline"
        end
        if cr_start and cr_start < next_event_start then
            next_event_start = cr_start
            event_type = "carriage_return"
        end

        if next_event_start > pos then
            write_chunk(text:sub(pos, next_event_start - 1))
        end

        if event_type == "escape" then
            if command == "m" then
                if params == "" or params == "0" then
                    target_term.setTextColor(colors.white)
                    target_term.setBackgroundColor(colors.black)
                else
                    for code_str in params:gmatch("%d+") do
                        local code = tonumber(code_str)
                        if code >= 30 and code <= 37 then
                            target_term.setTextColor(ansi_colors[code])
                        elseif code >= 40 and code <= 47 then
                            target_term.setBackgroundColor(ansi_colors[code])
                        end
                    end
                end
            elseif command == "H" then
                local r, c = params:match("(%d+);(%d+)")
                r = tonumber(r) or 1
                c = tonumber(c) or 1
                target_term.setCursorPos(c, r)
            elseif command == "J" and params == "2" then
                target_term.clear()
                target_term.setCursorPos(1, 1)
            elseif command == "K" and params == "2" then
                target_term.clearLine()
            elseif command == "D" then
                local n = tonumber(params) or 1
                local cx, cy = target_term.getCursorPos()
                target_term.setCursorPos(math.max(1, cx - n), cy)
            end
            pos = esc_end + 1

        elseif event_type == "newline" then
            local _, cy = target_term.getCursorPos()
            if cy >= h then
                target_term.scroll(1)
                target_term.setCursorPos(1, h)
            else
                target_term.setCursorPos(1, cy + 1)
            end
            pos = nl_end + 1

        elseif event_type == "carriage_return" then
            local _, cy = target_term.getCursorPos()
            target_term.setCursorPos(1, cy)
            pos = cr_end + 1

        else
            break
        end
    end
end

return tty