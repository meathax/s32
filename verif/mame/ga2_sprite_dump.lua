-- Dump the ga2 sprite RAM (V60 display list) at the PLAYER SELECT screen so the
-- character-sprite descriptors can be decoded and replayed through our renderer.
local maincpu = manager.machine.devices[":mainpcb:maincpu"]
local msp     = maincpu.spaces["program"]
local port    = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin    = port.fields["Coin 1"]
local start   = port.fields["1 Player Start"]

local function dump_spriteram(tag)
  local f = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_spriteram_"..tag..".hex", "w")
  for w = 0, 0xffff do
    f:write(string.format("%04x\n", msp:read_u16(0x400000 + w*2)))
  end
  f:close()
end

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 330 then coin:set_value(1) elseif fr == 330 then coin:set_value(0) end
  if fr >= 360 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 480 and fr < 500 then start:set_value(1) elseif fr == 500 then start:set_value(0) end
  if fr == 1000 then
    dump_spriteram("select")
    local cf = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_sprite_controls.txt", "w")
    for i = 0, 7 do cf:write(string.format("%02x\n", msp:read_u8(0x500000 + i*2) & 0xff)) end
    cf:close()
    manager.machine.video:snapshot()
  end
end)
