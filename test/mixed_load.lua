
print("Benchmark mixto iniciado")

local promises = {}

for i = 1, 6 do
    table.insert(promises, function()
        local id = i
        local mode = math.random(1,3)

        if mode == 1 then
            local sum = 0
            for j = 1, 20000000 do sum = sum + j end
            print("CPU " .. id .. " terminado")

        elseif mode == 2 then
            for j = 1, 5 do
                sleep(0.8)
                print("Sleep " .. id .. " - " .. j .. "/5")
            end
        else
            print("Waiter " .. id .. " esperando 'tick" .. id .. "'")
            os.pullEvent("tick" .. id)
            print("Waiter " .. id .. " liberado!")
        end
    end)
end

parallel.waitForAll(table.unpack(promises))

print("¡Carga mixta completada!")