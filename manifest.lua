return {
    directory = "Loom",
    files = {
        ["boot/config.lua"] = "src/boot/config.lua",
        ["boot/init.lua"] = "src/boot/init.lua",

        ["core/interrupt.lua"] = "src/core/interrupt.lua",
        ["core/kstate.lua"] = "src/core/kstate.lua",
        ["core/ksyscalls.lua"] = "src/core/ksyscalls.lua",
        ["core/scheduler.lua"] = "src/core/scheduler.lua",
        ["core/task.lua"] = "src/core/task.lua",

        ["drivers/net.lua"] = "src/drivers/net.lua",
        ["drivers/tty.lua"] = "src/drivers/tty.lua",

        ["fs/vfs.lua"] = "src/fs/vfs.lua",

        ["sec/krng.lua"] = "src/sec/krng.lua",
        ["sec/sandbox.lua"] = "src/sec/sandbox.lua",

        ["structs/heap/binary_heap.lua"] = "src/heap/binary_heap.lua",
        ["structs/heap/init.lua"] = "src/heap/init.lua",

        ["core.lua"] = "src/core.lua"
    },
    dependencies = nil
}