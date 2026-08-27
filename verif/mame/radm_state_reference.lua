-- Dump Rad Mobile's sprite RAM and tilemap VRAM at one deterministic frame.
-- Set RADM_STATE_FRAME (default 40) and RADM_STATE_DIR.

local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local frame = 0
local target = tonumber(os.getenv("RADM_STATE_FRAME") or "40")
local outdir = assert(os.getenv("RADM_STATE_DIR"), "RADM_STATE_DIR is required")

local function dump_words(path, base, words)
  local out = assert(io.open(path, "w"))
  for word = 0, words - 1 do
    out:write(string.format("%04x\n", mem:read_u16(base + word * 2)))
  end
  out:close()
end

_G.radm_state_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == target then
    dump_words(outdir .. "/mame_wram.hex",      0x200000, 0x8000)
    dump_words(outdir .. "/mame_spriteram.hex", 0x400000, 0x10000)
    dump_words(outdir .. "/mame_vram.hex",      0x300000, 0x10000)
    local log = assert(io.open(outdir .. "/mame_state.log", "w"))
    log:write(string.format("frame=%d pc=%08x\n",
      frame, cpu.state["PC"].value))
    log:close()
    machine:exit()
  end
end)
