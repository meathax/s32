-- Trace the early Rad Mobile writes that populate low tilemap VRAM.

local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local out = assert(io.open(assert(os.getenv("RADM_VRAM_TRACE")), "w"))
local frame = 0
local count = 0
local nonzero = 0

_G.radm_vram_tap = mem:install_write_tap(
  0x300000, 0x300fff, "radm_low_vram",
  function(offset, data, mask)
    if data ~= 0 and nonzero < 512 then
      out:write(string.format(
        "frame=%d pc=%08x addr=%08x data=%04x mask=%04x\n",
        frame, cpu.state["PC"].value, offset, data, mask))
      nonzero = nonzero + 1
    end
    count = count + 1
  end)

_G.radm_intc_tap = mem:install_write_tap(
  0xd00000, 0xd0000f, "radm_intc",
  function(offset, data, mask)
    out:write(string.format(
      "INTC frame=%d pc=%08x addr=%08x data=%04x mask=%04x\n",
      frame, cpu.state["PC"].value, offset, data, mask))
  end)

_G.radm_waitflag_write_tap = mem:install_write_tap(
  0x20eff0, 0x20f00f, "radm_waitflag_write",
  function(offset, data, mask)
    out:write(string.format(
      "WRAM-W frame=%d pc=%08x addr=%08x data=%04x mask=%04x\n",
      frame, cpu.state["PC"].value, offset, data, mask))
  end)

_G.radm_waitflag_read_tap = mem:install_read_tap(
  0x20eff0, 0x20f00f, "radm_waitflag_read",
  function(offset, data, mask)
    out:write(string.format(
      "WRAM-R frame=%d pc=%08x addr=%08x data=%04x mask=%04x\n",
      frame, cpu.state["PC"].value, offset, data, mask))
  end)

_G.radm_vram_frames = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == 12 then
    out:write(string.format("done writes=%d nonzero=%d\n", count, nonzero))
    out:close()
    out = nil
    machine:exit()
  end
end)
