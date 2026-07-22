-- Disassemble the char-select object build/init routines via the MAME debugger.
-- Run with: mame ga2 -debug -debugger none -autoboot_script this.lua
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local dbg = cpu.debug
local out = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_dasm.txt", "w")

local function dasm(lo, hi, tag)
  out:write("==== "..tag.." ("..string.format("%06x..%06x",lo,hi)..") ====\n")
  local a = lo
  while a <= hi do
    local s = dbg:disassemble(a)          -- returns disasm string
    -- disassemble returns text; step by instruction length via a second return?
    out:write(string.format("%06x: %s\n", a, s))
    -- v60 insns vary 1..11 bytes; advance by the debugger's reported size if any
    a = a + (dbg.disassemble and 1 or 1)   -- fallback; refined below
  end
end

-- Prefer the length-aware form if available
local function dasm2(lo, hi, tag)
  out:write("==== "..tag.." ("..string.format("%06x..%06x",lo,hi)..") ====\n")
  local a = lo
  while a <= hi do
    local s, len = dbg:disassemble(a)
    if not len or len < 1 then len = 1 end
    out:write(string.format("%06x: %s\n", a, s))
    a = a + len
  end
end

dasm2(0x130520, 0x130560, "INIT loop (clears object array)")
dasm2(0x132540, 0x1325a0, "BUILD loop (fills object array)")
out:close()
print("[dasm] done")
manager.machine:exit()
