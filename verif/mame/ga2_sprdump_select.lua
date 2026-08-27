-- Dump ga2's sprite display list (0x400000, 0x10000 words) at the interactive
-- PLAYER SELECT, in the same %04x-per-line format the Verilator tb emits, so
-- both can be decoded/diffed with scratch/decode_ga2_sprites.py.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 520 then
    manager.machine.video:snapshot()
    local f = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_spriteram_select.hex", "w")
    for a = 0x400000, 0x41fffe, 2 do
      f:write(string.format("%04x\n", msp:read_u16(a)))
    end
    f:close()
    print("[sprdump] wrote mame_spriteram_select.hex at frame "..fr)
  end
end)
