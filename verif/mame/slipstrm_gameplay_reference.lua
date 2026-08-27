-- Deterministic Slip Stream cold-boot/gameplay reference for MAME 0.289.
-- Captures the raw screen-device surface, bypassing layout_radr's shifter
-- artwork and renderer scaling.  Set S32_SLIPSTRM_DIR to an existing output
-- directory before launching MAME with -autoboot_script.

local machine = manager.machine
local screen = assert(machine.screens[":mainpcb:screen"])
local cpu = assert(machine.devices[":mainpcb:maincpu"])
local output_dir = assert(os.getenv("S32_SLIPSTRM_DIR"),
    "S32_SLIPSTRM_DIR is required")
local trace = assert(io.open(output_dir .. "/reference.jsonl", "w"))

local function find_field(name)
    for _, port in pairs(machine.ioport.ports) do
        for field_name, field in pairs(port.fields) do
            if field_name == name then return field end
        end
    end
    error("missing input field: " .. name)
end

local coin = find_field("Coin 1")
local start = find_field("1 Player Start")
local gear = find_field("mainpcb:Gear Change")
local accelerator = find_field("P1 Pedal 1")
local captures = { [500]=true, [620]=true, [690]=true,
                   [720]=true, [800]=true, [880]=true,
                   [1000]=true, [1200]=true, [1400]=true,
                   [1600]=true, [1800]=true, [2000]=true,
                   [2200]=true, [2400]=true, [2600]=true,
                   [2800]=true, [3000]=true, [3200]=true,
                   [3400]=true, [3600]=true, [3800]=true,
                   [4000]=true, [4200]=true }

local function write_ppm(frame)
    local pixels, width, height = screen:pixels()
    assert(#pixels == width * height * 4)
    local path = string.format("%s/frame_%06d.ppm", output_dir, frame)
    local file = assert(io.open(path, "wb"))
    file:write(string.format("P6\n%d %d\n255\n", width, height))
    local row = {}
    local source = 1
    for _y = 1, height do
        for x = 1, width do
            local blue, green, red = string.byte(pixels, source, source + 2)
            row[x] = string.char(red, green, blue)
            source = source + 4
        end
        file:write(table.concat(row))
    end
    file:close()
    return width, height
end

local frame = 0
_G.s32_slipstrm_reference = emu.add_machine_frame_notifier(function()
    frame = frame + 1

    -- Exact untainted edge schedule retained from the MAME MCP cold run.
    if frame == 240 then coin:set_value(1)
    elseif frame == 260 then coin:set_value(0)
    elseif frame == 320 then coin:set_value(1)
    elseif frame == 340 then coin:set_value(0)
    elseif frame == 460 then start:set_value(1)
    elseif frame == 490 then start:set_value(0)
    elseif frame == 620 then start:set_value(1)
    elseif frame == 623 then start:set_value(0)
    elseif frame == 680 then accelerator:set_value(255)
    elseif frame == 700 then gear:set_value(0)
    elseif frame == 703 then gear:set_value(1)
    end

    if captures[frame] then
        local width, height = write_ppm(frame)
        trace:write(string.format(
            '{"frame":%d,"pc":%d,"width":%d,"height":%d}\n',
            frame, cpu.state["PC"].value, width, height))
        trace:flush()
    end
    if frame >= 4200 then machine:exit() end
end)

emu.add_machine_stop_notifier(function()
    if trace then trace:close(); trace = nil end
end)
