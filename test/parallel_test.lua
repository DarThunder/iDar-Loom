parallel.waitForAll(

    function()
        local n = 0
        for i = 1, 40000000 do n = n + 1 end
        print("CPU terminado")
    end,

    function()  -- Sleeps
        for i = 1, 8 do
            sleep(1)
            print("Sleep " .. i .. "/8")
        end
    end,

    function()
        print("Esperando 'key'...")
        os.pullEvent("key_up")
        print("Evento 'go' recibido!")
    end
)

print("¡Todos los paralelos terminaron!")