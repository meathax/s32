local cpu = manager.machine.devices[":mainpcb:maincpu"]
local names = {}
for k,v in pairs(cpu.state) do table.insert(names, k) end
table.sort(names)
local out = assert(io.open("scratch/radm_regnames.txt","w"))
for _,n in ipairs(names) do out:write(n.."\n") end
out:close()
manager.machine:exit()
