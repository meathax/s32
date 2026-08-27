-- Find every PC that READS the timer0/timer1 tick counters (0x20f030-38),
-- across a wide frame window, to locate the comparison/threshold check that
-- (if any) gates a state transition on elapsed timer ticks.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = os.getenv("RADM_TRD_OUT") or "scratch/radm_timer_read_trace.txt"
local last_frame = tonumber(os.getenv("RADM_TRD_LAST")) or 905
local log = assert(io.open(out, "w"))
local frame = 0
local seen = {}
_G.radm_trd_r = mem:install_read_tap(0x20f030, 0x20f039, "radm_trd_r",
  function(offset, data, mask)
    local pc = cpu.state["PC"].value
    local key = string.format("%08x_%06x", pc, offset)
    if not seen[key] then
      seen[key] = true
      log:write(string.format("RD f=%d pc=%08x a=%06x d=%04x\n", frame, pc, offset, data & 0xffff))
    end
    return data
  end)
_G.radm_trd_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    log:write(string.format("# done frame=%d\n", frame))
    log:close(); log = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if log then log:close(); log = nil end end)
