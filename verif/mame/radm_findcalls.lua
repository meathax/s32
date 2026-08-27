local machine = manager.machine
local cpu = machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local out = assert(io.open("scratch/radm_findcalls.txt", "w"))
-- Search ROM (0x60000-0x80000, the code region seen throughout this session)
-- for any byte sequence containing the little-endian encoding of 0x066729
-- or 0x066731 (candidate call targets for the attract-system entry point).
local targets = {0x066729, 0x066731, 0x066735, 0x06672d}
for base = 0x60000, 0x7ffff do
  local b0 = mem:read_u8(base)
  local b1 = mem:read_u8(base+1)
  local b2 = mem:read_u8(base+2)
  local b3 = mem:read_u8(base+3)
  local val24 = b0 + b1*256 + b2*65536
  local val32 = val24 + b3*16777216
  for _, t in ipairs(targets) do
    if val24 == t or val32 == t then
      out:write(string.format("MATCH at rom=%06x target=%06x (24bit=%06x 32bit=%08x) bytes=%02x %02x %02x %02x\n",
        base, t, val24, val32, b0, b1, b2, b3))
    end
  end
end
out:close()
machine:exit()
