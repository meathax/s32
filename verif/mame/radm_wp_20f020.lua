-- Trace writes to work-RAM byte 0x20f020 (a state/mode flags byte).  Boot
-- code at PC 0x703d8 tests bit2 of this byte to decide whether to re-enter
-- the motor-warmup wait helper (0x7027a) or skip past it to 0x7042a.  Find
-- when/whether MAME clears bit2 -- that is the actual "warmup done" signal,
-- distinct from the interrupt-driven countdown which is just plumbing.
local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])

local out = os.getenv("RADM_WP_OUT") or "scratch/radm_wp_20f020.txt"
local last_frame = tonumber(os.getenv("RADM_WP_LAST")) or 120
local log = assert(io.open(out, "w"))

local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_WP_MAX")) or 5000

_G.radm_wp20_w = mem:install_write_tap(0x20f020, 0x20f021, "radm_wp20_w",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%02x\n",
        frame, cpu.state["PC"].value, offset, data & 0xff))
    end
    return data
  end)

_G.radm_wp20_r = mem:install_read_tap(0x20f020, 0x20f021, "radm_wp20_r",
  function(offset, data, mask)
    n = n + 1
    if n <= max_lines then
      log:write(string.format("RD f=%d pc=%08x a=%06x d=%02x\n",
        frame, cpu.state["PC"].value, offset, data & 0xff))
    end
    return data
  end)

_G.radm_wp20_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    log:write(string.format("# done frame=%d taps=%d pc=%08x byte20f020=%02x\n",
      frame, n, cpu.state["PC"].value, mem:read_u8(0x20f020)))
    log:close()
    log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
