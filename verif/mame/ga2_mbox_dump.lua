-- Dump the full 2KB MB8421 mailbox (V60 view, low byte lane) at boot vs. the
-- PLAYER SELECT screen, to see whether the V25 protection surface is static
-- after boot or changes at runtime.  Also snapshot to confirm the screen.
local maincpu = manager.machine.devices[":mainpcb:maincpu"]
local msp     = maincpu.spaces["program"]
local port    = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin    = port.fields["Coin 1"]
local start   = port.fields["1 Player Start"]

local function dump(tag)
  local f = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_mbox_"..tag..".hex", "w")
  for off = 0, 0x7ff do
    local b = msp:read_u8(0xa00000 + off*2)   -- low byte lane
    f:write(string.format("%02x", b))
    if (off % 32) == 31 then f:write("\n") end
  end
  f:close()
end

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 330 then coin:set_value(1) elseif fr == 330 then coin:set_value(0) end
  if fr >= 360 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 480 and fr < 500 then start:set_value(1) elseif fr == 500 then start:set_value(0) end
  if fr == 250 then dump("attract"); manager.machine.video:snapshot() end
  if fr == 1000 then dump("select"); manager.machine.video:snapshot() end
end)
