-- Trace writes to work-RAM 0x20f030-0x20f038 (the TIMER0/TIMER1-driven tick
-- counters incremented by the interrupt handlers at ROM 0x7f584/0x7f59c).
-- Used to compare hardware-timer tick RATE (ticks per video frame) between
-- MAME and the RTL -- a rate mismatch would explain why a "wait until N
-- ticks elapsed" gate resolves at a different real-frame count in each.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_TT_OUT") or "scratch/radm_timer_trace.txt"
local last_frame = tonumber(os.getenv("RADM_TT_LAST")) or 30
local log = assert(io.open(out, "w"))
local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_TT_MAX")) or 20000

_G.radm_tt_w = mem:install_write_tap(0x20f030, 0x20f039, "radm_tt_w",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%04x\n",
        frame, cpu.state["PC"].value, offset, data & 0xffff))
    end
    return data
  end)

_G.radm_tt_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    log:write(string.format("# done frame=%d taps=%d\n", frame, n))
    log:close(); log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
