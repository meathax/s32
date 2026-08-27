-- Trace writes to the System 32 interrupt controller (0xd00000-0xd0000f)
-- during Rad Mobile's early boot, to see the mask/vector/ack programming
-- sequence MAME's ROM performs before the VBSTOP-driven work-RAM 0x20f000
-- countdown (see radm_wp_20f000.lua) starts decrementing.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_INTC_OUT") or "scratch/radm_intc_trace.txt"
local last_frame = tonumber(os.getenv("RADM_INTC_LAST")) or 20
local log = assert(io.open(out, "w"))

local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_INTC_MAX")) or 20000

_G.radm_intc_w = mem:install_write_tap(0xd00000, 0xd0000f, "radm_intc_w",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%08x mask=%08x\n",
        frame, cpu.state["PC"].value, offset, data, mask))
    end
    return data
  end)

_G.radm_intc_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
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
