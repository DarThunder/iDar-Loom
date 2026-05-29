local net = {}

local function get_modem()
    return peripheral.find("modem")
end

function net.bind(pid, fd_obj, port)
    local modem = get_modem()
    if not modem then return false, "No modem attached" end

    modem.open(port)
    fd_obj.local_port = port
    fd_obj.status = "LISTENING"

    return true
end

function net.connect(pid, fd_obj, remote_id, remote_port)
    local modem = get_modem()
    if not modem then return false, "No modem attached" end

    if not fd_obj.local_port then
        local ephemeral_port = math.random(10000, 65000)
        local ok, err = net.bind(pid, fd_obj, ephemeral_port)
        if not ok then return false, err end
    end

    fd_obj.remote_id = remote_id
    fd_obj.remote_port = remote_port
    fd_obj.status = "ESTABLISHED"

    return true
end

function net.send(pid, fd_obj, data)
    local modem = get_modem()
    if not modem then return false, "No modem attached" end
    if fd_obj.status ~= "ESTABLISHED" then return false, "Socket not connected" end

    local raw_packet = {
        sender_id = iDarBoot.getHardware().computer_id,
        payload = data
    }

    modem.transmit(fd_obj.remote_port, fd_obj.local_port, raw_packet)
    return true
end

function net.close(pid, fd_obj)
    local modem = get_modem()
    modem.close(fd_obj.local_port)
end

return net