-- Reach ga2 (Golden Axe 2) CHARACTER SELECT, screenshot it, and dump the sprite
-- display list + tilemap VRAM so the "PLAYER SELECT" banner (white box in our
-- core) can be compared sprite/tilemap by sprite/tilemap vs our core.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]
local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 60 and fr < 90 then coin:set_value(1) elseif fr == 90 then coin:set_value(0) end
  if fr >= 120 and fr < 150 then start:set_value(1) elseif fr == 150 then start:set_value(0) end
  if fr >= 160 and fr <= 320 and (fr % 16) == 0 then manager.machine.video:snapshot() end
  if fr == 300 then
    local f = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_ga2_select_spr.hex","w")
    for a = 0x400000, 0x41fffe, 2 do f:write(string.format("%04x\n", msp:read_u16(a))) end
    f:close()
    local v = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_ga2_select_vram.hex","w")
    for a = 0x300000, 0x31fffe, 2 do v:write(string.format("%04x\n", msp:read_u16(a))) end
    v:close()
    -- raw paletteram (0x600000, 0x4000 words) to diff sprite/tilemap palettes
    local p = io.open("/mnt/d/Arcade/AI/s32/scratch/mame_ga2_select_pal.hex","w")
    for a = 0x600000, 0x607ffe, 2 do p:write(string.format("%04x\n", msp:read_u16(a))) end
    p:close()
    print(string.format("[ga2_pages] F40=%04x F42=%04x F44=%04x F46=%04x F5c=%04x F00=%04x F02=%04x",
      msp:read_u16(0x31FF40), msp:read_u16(0x31FF42), msp:read_u16(0x31FF44),
      msp:read_u16(0x31FF46), msp:read_u16(0x31FF5C), msp:read_u16(0x31FF00), msp:read_u16(0x31FF02)))
    print("[ga2_select] dumped sprite list + vram")
    manager.machine:exit()
  end
end)
