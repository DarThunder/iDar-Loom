print("Esperando evento 'test_event' ... presiona cualquier tecla para dispararlo")

while true do
    local ev = os.pullEvent("test_event")
    print("¡Evento recibido!", ev)
    break
end

print("Terminé de esperar")