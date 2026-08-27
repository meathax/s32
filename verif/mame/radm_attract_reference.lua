-- Deterministic Rad Mobile attract-mode reference capture.
-- Controls remain at MAME defaults: wheel centred, accelerator/brake released.

local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local video = machine.video

local out = os.getenv("RADM_ATTRACT_TRACE") or
  "scratch/mame_radm_attract/trace.log"
local log = assert(io.open(out, "w"))
local frame = 0
local default_frames =
  "120,240,360,480,600,900,1200,1500,1800,2100,2400"
local capture_frames = {}
local last_frame = 0
for value in string.gmatch(
    os.getenv("RADM_ATTRACT_FRAMES") or default_frames, "%d+") do
  local requested = assert(tonumber(value))
  capture_frames[requested] = true
  last_frame = math.max(last_frame, requested)
end
assert(last_frame > 0, "RADM_ATTRACT_FRAMES contains no frame numbers")

local function port_value(tag)
  local port = machine.ioport.ports[tag]
  return port and port:read() or 0xffffffff
end

local function emit(kind)
  log:write(string.format(
    "[%s] frame=%d pc=%08x wheel=%02x gas=%02x brake=%02x " ..
    "p1=%02x spr0=%04x vram=%04x\n",
    kind, frame, cpu.state["PC"].value,
    port_value(":mainpcb:ANALOG1"),
    port_value(":mainpcb:ANALOG2"),
    port_value(":mainpcb:ANALOG3"),
    port_value(":mainpcb:P1_A"),
    mem:read_u16(0x204000), mem:read_u16(0x203f40)))
  log:flush()
end

_G.radm_attract_driver = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if capture_frames[frame] then
    emit("landmark")
    video:snapshot()
  end
  if frame >= last_frame then
    emit("done")
    machine:exit()
  end
end)

emu.add_machine_stop_notifier(function()
  if log then
    log:close()
    log = nil
  end
end)
