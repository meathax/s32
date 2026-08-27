-- Generic deterministic System 32 frame capture for MAME-vs-Verilator review.
-- The caller supplies S32_MAME_FRAMES as a comma-separated list and exits at
-- the last requested emulated frame.  Snapshots are written by MAME using the
-- normal -snapshot_directory/-snapname options.

local machine = manager.machine
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local video = machine.video

local trace_path = os.getenv("S32_MAME_TRACE") or "scratch/mame_frames.log"
local log = assert(io.open(trace_path, "w"))
local capture = {}
local last_frame = 0
for value in string.gmatch(os.getenv("S32_MAME_FRAMES") or "80", "%d+") do
    local frame = assert(tonumber(value))
    capture[frame] = true
    last_frame = math.max(last_frame, frame)
end
assert(last_frame > 0, "S32_MAME_FRAMES contains no frame number")

local function emit(kind, frame)
    log:write(string.format(
        "[%s] frame=%d pc=%08x spr0=%04x vram=%04x\n",
        kind, frame, cpu.state["PC"].value,
        mem:read_u16(0x204000), mem:read_u16(0x203f40)))
    log:flush()
end

local frame = 0
_G.s32_frame_capture = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if capture[frame] then
        emit("landmark", frame)
        video:snapshot()
    end
    if frame >= last_frame then
        emit("done", frame)
        machine:exit()
    end
end)

emu.add_machine_stop_notifier(function()
    if log then
        log:close()
        log = nil
    end
end)
