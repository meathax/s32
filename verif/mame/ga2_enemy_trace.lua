-- Deterministic Golden Axe enemy-contact reference scenario.
-- Drives the same schedule as tb_core_romboot +PLAYFIGHT and records both
-- sides of the V60<->V25 mailbox.  The trace is architectural: frame, writer,
-- mailbox byte offset, data, mask, and executing CPU PC.
local maincpu = assert(manager.machine.devices[":mainpcb:maincpu"])
local mcu = assert(manager.machine.devices[":mainpcb:mcu"])
local msp = assert(maincpu.spaces["program"])
local usp = assert(mcu.spaces["program"])
local svc = assert(manager.machine.ioport.ports[":mainpcb:SERVICE12_A"])
local p1 = assert(manager.machine.ioport.ports[":mainpcb:P1_A"])
local coin = assert(svc.fields["Coin 1"])
local start = assert(svc.fields["1 Player Start"])
local attack = assert(p1.fields["P1 Button 1"])
local right = assert(p1.fields["P1 Right"])

local output = os.getenv("GA2_ENEMY_TRACE_OUT") or
  "/mnt/d/Arcade/AI/s32/scratch/mame_ga2_enemy_trace.csv"
local log = assert(io.open(output, "w"))
log:write("frame,who,pc,off,data,mask\n")
local frame = 0
local v60_writes = 0
local v25_writes = 0

local function cpu_pc(cpu)
  local ok, value = pcall(function() return cpu.state["PC"].value end)
  if ok and value then return value end
  return 0
end

_G.ga2_enemy_v60_write = msp:install_write_tap(
  0xa00000, 0xa00fff, "ga2_enemy_v60w",
  function(offset, data, mask)
    v60_writes = v60_writes + 1
    log:write(string.format("%d,V60W,%06x,%03x,%04x,%04x\n",
      frame, cpu_pc(maincpu), ((offset - 0xa00000) >> 1) & 0x7ff,
      data & 0xffff, mask & 0xffff))
  end)

_G.ga2_enemy_v25_write = usp:install_write_tap(
  0x10000, 0x1ffff, "ga2_enemy_v25w",
  function(offset, data, mask)
    v25_writes = v25_writes + 1
    log:write(string.format("%d,V25W,%05x,%03x,%04x,%04x\n",
      frame, cpu_pc(mcu), (offset - 0x10000) & 0x7ff,
      data & 0xffff, mask & 0xffff))
  end)

_G.ga2_enemy_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1

  coin:set_value((frame >= 300 and frame < 390) and 1 or 0)
  start:set_value((frame >= 430 and frame < 450) and 1 or 0)
  attack:set_value(0)
  right:set_value(0)

  -- Character selection: START+ATTACK taps, then a quiet timeout window.
  if frame >= 470 and frame < 600 and (frame % 40) < 6 then
    start:set_value(1)
    attack:set_value(1)
  end

  -- Gameplay autopilot: advance right and repeatedly attack without magic.
  if frame >= 680 then right:set_value(1) end
  if frame >= 700 and (frame % 25) < 5 then attack:set_value(1) end

  if frame >= 600 and frame % 100 == 0 then
    manager.machine.video:snapshot()
    log:write(string.format("# landmark frame=%d v60w=%d v25w=%d\n",
      frame, v60_writes, v25_writes))
    log:flush()
  end

  if frame == 2600 then
    log:write(string.format("# done frame=%d v60w=%d v25w=%d\n",
      frame, v60_writes, v25_writes))
    log:close()
    print(string.format("[ga2_enemy_trace] done v60w=%d v25w=%d", v60_writes, v25_writes))
    manager.machine:exit()
  end
end)
