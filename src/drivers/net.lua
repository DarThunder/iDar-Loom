local vfs = require("iDar.boot.Loom.fs.vfs")

local net = {}

local port_map = {}
local modem_side = nil

function net.init()
    modem_side = peripheral.find("modem")
    if modem_side then
        peripheral.call(peripheral.getName(modem_side), "closeAll")
    end
end

local function get_modem()
    if not modem_side then net.init() end
    return modem_side and peripheral.wrap(peripheral.getName(modem_side)) or nil
end

function net.bind(node, port)
    local modem = get_modem()
    if not modem then return false, "No modem attached" end
    if port_map[port] then return false, "Port already in use" end

    modem.open(port)
    port_map[port] = node
    node.local_port = port
    node.status = "LISTENING"

    return true
end

function net.connect(node, remote_id, remote_port)
    local modem = get_modem()
    if not modem then return false, "No modem attached" end

    if not node.local_port then
        local ephemeral_port = math.random(10000, 65000)
        while port_map[ephemeral_port] do
            ephemeral_port = math.random(10000, 65000)
        end
        local ok, err = net.bind(node, ephemeral_port)
        if not ok then return false, err end
    end

    node.remote_id = remote_id
    node.remote_port = remote_port
    node.status = "ESTABLISHED"

    return true
end

function net.close(node)
    if node.local_port then
        local modem = get_modem()
        if modem then modem.close(node.local_port) end
        port_map[node.local_port] = nil
        node.local_port = nil
    end
    node.status = "CLOSED"
    return true
end

function net.handle_modem_message(local_port, reply_port, raw_packet)
    local node = port_map[local_port]

    if not node then return nil end

    if type(raw_packet) == "table" and raw_packet.sender_id then
        if node.remote_id and node.remote_id ~= raw_packet.sender_id then
            return nil
        end
        if #node.buffer >= 50 then
            table.remove(node.buffer, 1)
        end

        table.insert(node.buffer, {
            sender = raw_packet.sender_id,
            payload = raw_packet.payload,
            reply_port = reply_port
        })

        if node.waiting_pid then
            local wake_pid = node.waiting_pid
            node.waiting_pid = nil
            return wake_pid
        end
    end

    return nil
end

function net.send(node, data)
    local modem = get_modem()
    if not modem then return false, "No modem attached" end
    if node.status ~= "ESTABLISHED" then return false, "Socket not connected" end

    local raw_packet = {
        sender_id = iDarBoot.getHardware().computer_id,
        payload = data
    }

    modem.transmit(node.remote_port, node.local_port, raw_packet)
    return true
end

function net.recv(node, pid)
    local data, err = vfs.read(node)

    if err == "EAGAIN" then
        node.waiting_pid = pid
        return "BLOCK"
    end

    return true, data
end

return net