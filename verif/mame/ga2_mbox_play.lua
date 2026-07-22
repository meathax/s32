-- Capture the ga2 V60<->V25 mailbox exchange while auto-inserting coin + start
-- so the RUNTIME protection (char-select sprite gen, enemy AI) actually runs.
local maincpu = manager.machine.devices[":mainpcb:maincpu"]
local mcu     = manager.machine.devices[":mainpcb:mcu"]
local msp     = maincpu.spaces["program"]
local usp     = mcu.spaces["program"]

local out = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_mbox_play.csv", "w")
out:write("cyc,who,off,data,mask\n")

local function mcyc()
  local ok, v = pcall(function() return mcu:total_cycles() end)
  if ok and v then return v end
  return math.floor(manager.machine.time:as_double() * 10000000.0)
end

_G.tapv60w = msp:install_write_tap(0xa00000, 0xa00fff, "v60w",
  function(offset, data, mask)
    out:write(string.format("%d,V60w,%03x,%04x,%04x\n", mcyc(), ((offset-0xa00000) >> 1) & 0x7ff, data & 0xffff, mask & 0xffff))
  end)
_G.tapv25w = usp:install_write_tap(0x10000, 0x1ffff, "v25w",
  function(offset, data, mask)
    out:write(string.format("%d,V25w,%03x,%04x,%04x\n", mcyc(), (offset-0x10000) & 0x7ff, data & 0xffff, mask & 0xffff))
  end)

local port = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = port.fields["Coin 1"]
local start = port.fields["1 Player Start"]
-- a P1 attack button to get through the select screen
local p1    = manager.machine.ioport.ports[":mainpcb:P1_A"]

local b1 = p1 and p1.fields["P1 Button 1"] or nil
local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  -- coin timing proven to reach PLAYER SELECT (two ~0.5s holds)
  if fr >= 300 and fr < 330 then coin:set_value(1) elseif fr == 330 then coin:set_value(0) end
  if fr >= 360 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 480 and fr < 500 then start:set_value(1) elseif fr == 500 then start:set_value(0) end
  -- from the select screen on, mash button 1 (confirm char) + occasional start
  if fr > 520 and b1 then
    if (fr % 24) < 5 then b1:set_value(1) else b1:set_value(0) end
  end
  if fr > 700 and (fr % 300) < 8 then start:set_value(1) elseif fr > 700 and (fr % 300) == 8 then start:set_value(0) end
  out:flush()
end)
