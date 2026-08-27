-- Tap the V25 (mcu) PROGRAM space (MB8421 mirror at 0x10000-0x1FFFF) during one
-- deck-demo frame to see the per-frame protection transform: what the V25 reads
-- (V60's 258-word input block) and writes back (results the game consumes).
local mcu = manager.machine.devices[":mainpcb:mcu"]
local sp  = mcu.spaces["program"]
local fr = 0
local out = io.open("/mnt/d/Arcade/AI/s32/scratch/arab_v25side.txt", "w")
local logging = false
sp:install_read_tap(0x10000, 0x11FFF, "v25rd", function(offset, data, mask)
  if logging then out:write(string.format("f=%d RD %05x = %02x\n", fr, offset, data & 0xff)) end
end)
sp:install_write_tap(0x10000, 0x11FFF, "v25wr", function(offset, data, mask)
  if logging then out:write(string.format("f=%d WR %05x = %02x\n", fr, offset, data & 0xff)) end
end)
_G.t = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  logging = (fr == 100)
  if fr == 101 then print("[v25side] done"); out:close(); manager.machine:exit() end
end)
