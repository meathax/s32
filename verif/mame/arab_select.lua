-- Reach arabfgt SELECT PLAYER (coin+start) and capture a screenshot + the sprite
-- display list, to compare the swirl/portrait load vs our core.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 340 then coin:set_value(1) elseif fr == 340 then coin:set_value(0) end
  if fr >= 370 and fr < 400 then start:set_value(1) elseif fr == 400 then start:set_value(0) end
  if fr >= 405 and fr <= 520 and (fr % 12) == 0 then manager.machine.video:snapshot() end
  if fr == 500 then
    local f = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_arab_select_spr.hex","w")
    for a = 0x400000, 0x41fffe, 2 do f:write(string.format("%04x\n", msp:read_u16(a))) end
    f:close()
    -- full tilemap VRAM (videoram at maincpu 0x300000, 0x10000 words) so the
    -- NBG name tables can be diffed vs our core's sim_vram.hex
    local v = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_arab_select_vram.hex","w")
    for a = 0x300000, 0x31fffe, 2 do v:write(string.format("%04x\n", msp:read_u16(a))) end
    v:close()
    -- tilemap page registers (videoram $1FF40.. at maincpu 0x31FF40)
    print(string.format("[arab_pages] F40=%04x F42=%04x F44=%04x F46=%04x F5c=%04x F00=%04x",
      msp:read_u16(0x31FF40), msp:read_u16(0x31FF42), msp:read_u16(0x31FF44),
      msp:read_u16(0x31FF46), msp:read_u16(0x31FF5C), msp:read_u16(0x31FF00)))
    print("[arab_select] dumped sprite list")
    manager.machine:exit()
  end
end)
