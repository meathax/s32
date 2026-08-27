-- Capture MAME's raw screen_device::pixels() surface at deterministic frames.
-- This deliberately bypasses video:snapshot(), the renderer, and the desktop.
-- Environment:
--   S32_RAW_DIR     output directory (required)
--   S32_RAW_FRAMES  comma-separated native frame tokens (default: 80)
--   S32_RAW_TRACE   optional state JSONL path
--   S32_RAW_NATIVE5 write a companion P6 PPM with maxval=31, containing the
--                   native 5-bit RGB channels before 8-bit presentation

local machine = manager.machine
local screen = assert(machine.screens[":mainpcb:screen"])
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local mem = assert(cpu.spaces["program"])
local output_dir = assert(os.getenv("S32_RAW_DIR"), "S32_RAW_DIR is required")
local trace_path = os.getenv("S32_RAW_TRACE") or (output_dir .. "/reference_state.jsonl")
local trace = assert(io.open(trace_path, "w"))
local native5_enabled = os.getenv("S32_RAW_NATIVE5") == "1"
local requested = {}
local final_frame = 0

for value in string.gmatch(os.getenv("S32_RAW_FRAMES") or "80", "%d+") do
    local token = assert(tonumber(value))
    requested[token] = true
    final_frame = math.max(final_frame, token)
end
assert(final_frame > 0, "S32_RAW_FRAMES contains no frame tokens")

local function write_raw_surfaces(token)
    local pixels, width, height = screen:pixels()
    assert(#pixels == width * height * 4, "unexpected screen:pixels byte count")
    local temporary = string.format("%s/frame_%06d.ppm.tmp", output_dir, token)
    local final = string.format("%s/frame_%06d.ppm", output_dir, token)
    local file = assert(io.open(temporary, "wb"))
    local native5_temporary
    local native5_final
    local native5_file
    if native5_enabled then
        native5_temporary = string.format("%s/frame_%06d.rgb5.ppm.tmp", output_dir, token)
        native5_final = string.format("%s/frame_%06d.rgb5.ppm", output_dir, token)
        native5_file = assert(io.open(native5_temporary, "wb"))
        native5_file:write(string.format("P6\n%d %d\n31\n", width, height))
    end
    file:write(string.format("P6\n%d %d\n255\n", width, height))

    -- screen_device::pixels() returns packed 0xAARRGGBB u32 values in host
    -- endian order.  The supported Windows MAME build is little-endian, so
    -- the byte string is BGRA; write the exact same surface as RGB P6.
    local row = {}
    local native5_row = {}
    local source = 1
    for _y = 1, height do
        for x = 1, width do
            local blue, green, red = string.byte(pixels, source, source + 2)
            row[x] = string.char(red, green, blue)
            if native5_enabled then
                native5_row[x] = string.char(
                    math.floor(red / 8), math.floor(green / 8), math.floor(blue / 8))
            end
            source = source + 4
        end
        file:write(table.concat(row))
        if native5_enabled then native5_file:write(table.concat(native5_row)) end
    end
    file:close()
    assert(os.rename(temporary, final))
    if native5_enabled then
        native5_file:close()
        assert(os.rename(native5_temporary, native5_final))
    end
    return width, height
end

local frame = 0
_G.s32_raw_frame_capture = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if requested[frame] then
        local width, height = write_raw_surfaces(frame)
        trace:write(string.format(
            '{"frame":%d,"boundary":"machine_frame_notifier_after_update",' ..
            '"width":%d,"height":%d,"native5":%s,"pc":%d,"spr0":%d,"vram":%d}\n',
            frame, width, height, native5_enabled and "true" or "false",
            cpu.state["PC"].value,
            mem:read_u16(0x204000), mem:read_u16(0x203f40)))
        trace:flush()
    end
    if frame >= final_frame then
        machine:exit()
    end
end)

emu.add_machine_stop_notifier(function()
    if trace then
        trace:close()
        trace = nil
    end
end)
