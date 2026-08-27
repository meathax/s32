-- Deterministic Holosseum MAME reference capture.
--
-- This is intentionally an autoboot script instead of a MAME plugin so it can
-- run against a stock packaged MAME build.  The companion PowerShell wrapper
-- supplies the output directory, ROM path and fixed run duration.

local machine = manager.machine
local video = machine.video
local trace_path = os.getenv("S32_MAME_TRACE")
local trace = nil
local frame = 0
local fields = {}

if trace_path and trace_path ~= "" then
    trace = assert(io.open(trace_path, "w"))
    trace:write("frame,pc,event\n")
    trace:flush()
end

local function emit(event)
    local pc = 0
    local ok, value = pcall(function()
        return machine.devices[":maincpu"].state["PC"].value
    end)
    if ok then pc = value end
    local line = string.format("%d,%08x,%s\n", frame, pc, event or "")
    if trace then
        trace:write(line)
        trace:flush()
    end
    print("S32_MAME_REF " .. line:gsub("\n", ""))
end

local function remember_fields()
    for _, port in pairs(machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            fields[field.name] = field
        end
    end
end

local function find_field(pattern)
    for name, field in pairs(fields) do
        if string.find(string.lower(name), pattern, 1, true) then
            return field, name
        end
    end
    return nil, nil
end

local function drive(pattern, active, event)
    local field, name = find_field(pattern)
    if field then
        field:set_value(active and 1 or 0)
        emit((event or pattern) .. ":" .. name .. ":" .. (active and "down" or "up"))
    elseif active then
        emit("missing-input:" .. pattern)
    end
end

local snapshots = {
    [1] = true,
    [120] = true,
    [300] = true,
    [360] = true,
    [600] = true,
    [900] = true,
    [1200] = true
}

remember_fields()
emit("capture-start")

emu.register_frame_done(function()
    frame = frame + 1

    if snapshots[frame] then
        video:snapshot()
        emit("snapshot")
    elseif (frame % 60) == 0 then
        emit("heartbeat")
    end

    -- Fixed, frame-based attract-to-play script.  Pulses are long enough to
    -- cross the game's input sampling without introducing host timing.
    if frame == 300 then drive("coin 1", true, "coin") end
    if frame == 304 then drive("coin 1", false, "coin") end
    if frame == 360 then drive("1 player start", true, "start") end
    if frame == 364 then drive("1 player start", false, "start") end
    if frame == 600 then drive("p1 right", true, "right") end
    if frame == 780 then drive("p1 right", false, "right") end
    if frame == 660 then drive("p1 button 1", true, "button1") end
    if frame == 664 then drive("p1 button 1", false, "button1") end
end, "s32_holo_reference")

emu.add_machine_stop_notifier(function()
    emit("capture-stop")
    if trace then
        trace:close()
        trace = nil
    end
end)
