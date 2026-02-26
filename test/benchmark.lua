local loom = require("..iDar.Loom.src.core")

loom.launch("/test/cpu_stress.lua")
--loom.launch("/test/sleep_spam.lua")
--loom.launch("/test/parallel_test.lua")
--loom.launch("/test/even_waiter.lua")

loom.execute()
