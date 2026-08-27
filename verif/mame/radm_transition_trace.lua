-- Trace ALL work-RAM writes during the narrow frame window where MAME
-- transitions off the "Motor warm up" wait screen (frame ~900-960 per
-- verif/mame/compare_s32_attract.py against the RTL capture).  Narrower
-- than a full state dump diff, which is swamped by ordinary per-frame
-- gameplay churn once the demo starts.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_TR_OUT") or "scratch/radm_transition_trace.txt"
local start_frame = tonumber(os.getenv("RADM_TR_START")) or 895
local last_frame = tonumber(os.getenv("RADM_TR_LAST")) or 930
local log = assert(io.open(out, "w"))

local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_TR_MAX")) or 200000
local active = false

_G.radm_tr_w = mem:install_write_tap(0x200000, 0x20ffff, "radm_tr_w",
  function(offset, data, mask)
    if active and n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%04x mask=%04x\n",
        frame, cpu.state["PC"].value, offset, data, mask))
      n = n + 1
    end
    return data
  end)

_G.radm_tr_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  active = (frame >= start_frame)
  if frame >= last_frame then
    log:write(string.format("# done frame=%d taps=%d pc=%08x\n", frame, n, cpu.state["PC"].value))
    log:close()
    log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
