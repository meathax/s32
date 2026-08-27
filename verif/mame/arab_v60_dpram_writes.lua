-- Arabian Fight V60-side MB8421 writes, same trajectory as
-- arab_v25_boot_vector.lua.  Tells us when the V25's output first depends on
-- V60 input, which bounds how far a V60-less RTL replay can be trusted.
--
-- V60 side of the dual-port RAM is 0xA00000-0xA00fff, low byte lane, so the
-- shared offset is ((address - 0xA00000) >> 1) & 0x7ff.

local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local space = assert(cpu.spaces["program"])

local out_path = os.getenv("ARAB_V60_OUT") or "scratch/arab_v25_boot/v60_writes.txt"
local last_frame = tonumber(os.getenv("ARAB_V60_FRAMES") or "120")
local max_writes = tonumber(os.getenv("ARAB_V60_MAX") or "20000")
local log = assert(io.open(out_path, "w"))

local frame = 0
local seq = 0
local per_frame = 0

_G.arab_v60_write_tap = space:install_write_tap(0xa00000, 0xa00fff, "arab_v60_wr",
  function(offset, data, mask)
    seq = seq + 1
    per_frame = per_frame + 1
    if seq <= max_writes then
      log:write(string.format("%d f=%d off=%03x d=%04x mask=%04x pc=%08x\n",
        seq, frame, ((offset - 0xa00000) >> 1) & 0x7ff, data & 0xffff,
        mask & 0xffff, cpu.state["PC"].value))
    end
    return data
  end)

_G.arab_v60_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  log:write(string.format("# frame %d writes=%d total=%d\n", frame, per_frame, seq))
  per_frame = 0
  if frame >= last_frame then
    log:write(string.format("# done frames=%d writes=%d\n", frame, seq))
    log:close()
    log = nil
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then log:close(); log = nil end
end)
