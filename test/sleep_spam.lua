print("Iniciando 100 sleeps de 0.1s cada uno...")

local start = os.epoch("utc")

for i = 1, 100 do
    sleep(0.1)
    if i % 10 == 0 then
        print(i .. " sleeps completados - tiempo transcurrido: " .. (os.epoch("utc") - start)/1000 .. "s")
    end
end

print("¡Listo! Tiempo real:", (os.epoch("utc") - start)/1000 .. "s")