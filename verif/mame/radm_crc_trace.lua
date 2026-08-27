local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local out = assert(io.open("scratch/radm_crc_trace.txt", "w"))
local last_frame = tonumber(os.getenv("RADM_CRC_LAST")) or 8
local frame = 0
local n = 0
local max_n = tonumber(os.getenv("RADM_CRC_MAX")) or 60
-- read_tap on the loop's own dbr instruction bytes isn't reliable for
-- catching PC (opcode fetches don't trigger data taps in this MAME build).
-- Use a write tap on the destination word (0x20f500, the checksum result
-- being assembled) plus periodic register snapshots via frame notifier
-- won't catch mid-frame state either. Instead, tap the table lookup site's
-- source table read (0x067f80ish literal table) is ROM, not RAM, so taps
-- won't fire on code/ROM reads. Fall back to sampling R2/R6 at the WRITE of
-- the final result (0x20f500) to at least confirm the END value.
local mem = cpu.spaces["program"]
_G.radm_crc_w = mem:install_write_tap(0x20f500, 0x20f501, "radm_crc_w",
  function(offset, data, mask)
    n = n + 1
    out:write(string.format("WR f=%d pc=%08x a=%06x d=%04x r2=%02x r6=%04x\n",
      frame, cpu.state["PC"].value, offset, data & 0xffff,
      cpu.state["R2"].value & 0xff, cpu.state["R6"].value & 0xffff))
    return data
  end)
_G.radm_crc_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= last_frame then
    out:write(string.format("# done frame=%d n=%d\n", frame, n))
    out:close(); out = nil
    machine:exit()
  end
end)
emu.add_machine_stop_notifier(function() if out then out:close(); out = nil end end)
