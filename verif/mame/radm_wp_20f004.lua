local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = os.getenv("RADM_WP4_OUT") or "scratch/radm_wp_20f004.txt"
local last_frame = tonumber(os.getenv("RADM_WP4_LAST")) or 910
local log = assert(io.open(out, "w"))
local frame = 0
local n = 0
local max_lines = tonumber(os.getenv("RADM_WP4_MAX")) or 4000
local last_val = -1
_G.radm_wp4_w = mem:install_write_tap(0x20f004, 0x20f005, "radm_wp4_w",
  function(offset, data, mask)
    if n <= max_lines then
      log:write(string.format("WR f=%d pc=%08x a=%06x d=%04x\n",
        frame, cpu.state["PC"].value, offset, data & 0xffff))
      n = n + 1
    end
    return data
  end)
_G.radm_wp4_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    log:write(string.format("# done frame=%d taps=%d val=%02x\n", frame, n, mem:read_u8(0x20f004)))
    log:close(); log = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if log then log:close(); log = nil end end)
