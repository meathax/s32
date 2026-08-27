-- Find the V60 routine that writes the char-select CHARACTER BODY descriptors.
-- MAME sprite descriptor idx 0x806 (first missing-in-sim body piece) = spriteram
-- word 0x806*8=0x4030 -> maincpu byte 0x400000+0x4030*2 = 0x408060.
-- Tap writes to the command word of descriptors 0x804..0x80a and log the PC, so
-- we learn the composition loop's address + how MAME emits the body pieces our
-- V60 skips. Runs to the interactive PLAYER SELECT via coin+start.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]

local log = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_sprwrite_pc.txt", "w")
local hits = {}
-- Tap the WHOLE sprite-RAM window incl mirrors (0x400000-0x4fffff), mask the
-- offset to the 0x20000 aperture, and log writes landing in descriptors
-- 0x804..0x815 (idx*16 = 0x8040..0x815f) with the writing PC.
local tap = msp:install_write_tap(0x400000, 0x4fffff, "sprbody", function(offset, data, mask)
  local ap = offset & 0x1ffff
  if ap < 0x8040 or ap > 0x815f then return end
  local pc = cpu.state["PC"].value
  local desc = ap//16
  local word = (ap%16)//2
  local key = string.format("desc=%03x w%d pc=%06x data=%04x mir=%06x", desc, word, pc, data, offset)
  if not hits[key] then
    hits[key] = true
    log:write(key.."\n")
    log:flush()
  end
end)

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 540 then log:write("--- reached frame 540 ---\n"); log:close(); print("[sprwrite] done") end
end)
