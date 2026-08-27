-- Trace writes to work-RAM word 0x20f000 during Rad Mobile's early boot.
-- Our RTL spins forever reading this address at PC 0x70285 (0x70289 -> 0x70285
-- backward branch) waiting for it to become nonzero -- multiple past sessions
-- (scratch/radm_*_fix_run.log, 2026-07-31) hit the identical stall.  Find what
-- MAME's own code path does: which routine writes this word, from where, and
-- under what trigger (interrupt vs polled counter).
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_WP_OUT") or "scratch/radm_wp_20f000.txt"
local last_frame = tonumber(os.getenv("RADM_WP_LAST")) or 200
local log = assert(io.open(out, "w"))

local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_WP_MAX")) or 5000

_G.radm_wp_w = mem:install_write_tap(0x20f000, 0x20f003, "radm_wp_w",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%08x mask=%08x\n",
        frame, cpu.state["PC"].value, offset, data, mask))
    end
    return data
  end)

-- Also track reads at the RTL's stall PC's address to see if/when MAME's
-- equivalent poll loop (if any) samples the word, and what it reads.
_G.radm_wp_r = mem:install_read_tap(0x20f000, 0x20f003, "radm_wp_r",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("RD f=%d pc=%08x a=%06x d=%08x\n",
        frame, cpu.state["PC"].value, offset, data))
    end
    return data
  end)

_G.radm_wp_driver = emu.add_machine_frame_notifier(function()
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
