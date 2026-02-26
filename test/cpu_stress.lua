local start = os.clock()

local count = 0
for i = 1, 999999999 do
    count = count + i % 17 * 3
    if i % 500000 == 0 then
        print("Progreso: " .. i .. "  |  tiempo: " .. (os.clock() - start))
    end
end

print("¡Terminó! Total iteraciones ~1e9, tiempo:", os.clock() - start)