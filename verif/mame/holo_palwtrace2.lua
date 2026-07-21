-- Wide palette-window write trace incl. mirrors: which window do the
-- animated (fade) writes use, and how bursty are they per frame?
local machine = manager.machine
local dumpdir = os.getenv("S32_DUMP_DIR") or "."
local frame = 0
local buckets = { lo_native = 0, hi_native = 0, lo_alias = 0, hi_alias = 0, mixer = 0 }
local perframe = 0
local maxframe = 0
local late = {}
local laten = 0
local fields = {}
local tap = nil

local function remember_fields()
    for _, port in pairs(machine.ioport.ports) do
        for _, field in pairs(port.fields) do fields[field.name] = field end
    end
end
local function find_field(pattern)
    for name, field in pairs(fields) do
        if string.find(string.lower(name), pattern, 1, true) then return field end
    end
    return nil
end
local function drive(pattern, active)
    local f = find_field(pattern)
    if f then f:set_value(active and 1 or 0) end
end

local function install()
    local dev = machine.devices[":mainpcb:maincpu"] or machine.devices[":maincpu"]
    local sp = dev.spaces["program"]
    -- Keep a global reference: MAME removes taps whose handle is GC'd.
    _G.s32_palw_tap = sp:install_write_tap(0x600000, 0x6fffff, "palw2", function(offset, data, mask)
        if (offset & 0x10000) ~= 0 then
            buckets.mixer = buckets.mixer + 1
            return
        end
        local o = offset & 0xffff
        if o < 0x4000 then buckets.lo_native = buckets.lo_native + 1
        elseif o < 0x8000 then buckets.hi_native = buckets.hi_native + 1
        elseif o < 0xc000 then buckets.lo_alias = buckets.lo_alias + 1
        else buckets.hi_alias = buckets.hi_alias + 1 end
        perframe = perframe + 1
        if frame > 250 and laten < 40 then
            laten = laten + 1
            late[laten] = string.format("f%d %06x=%04x&%04x", frame, offset, data, mask)
        end
    end)
end

local function report(tag)
    local f = assert(io.open(string.format("%s/palw2-%04d-%s.txt", dumpdir, frame, tag), "w"))
    f:write(string.format("lo_native=%d hi_native=%d lo_alias=%d hi_alias=%d mixer=%d maxperframe=%d\n",
        buckets.lo_native, buckets.hi_native, buckets.lo_alias, buckets.hi_alias,
        buckets.mixer, maxframe))
    f:write("post-attract writes:\n")
    for i = 1, laten do f:write(late[i] .. "\n") end
    f:close()
    print(string.format("S32_PALW2 %s lo_n=%d hi_n=%d lo_a=%d hi_a=%d mix=%d maxpf=%d",
        tag, buckets.lo_native, buckets.hi_native, buckets.lo_alias, buckets.hi_alias,
        buckets.mixer, maxframe))
end

remember_fields()
install()

emu.register_frame_done(function()
    frame = frame + 1
    if perframe > maxframe then maxframe = perframe end
    perframe = 0
    if frame == 240 then report("attract") end
    if frame == 300 then drive("coin 1", true) end
    if frame == 304 then drive("coin 1", false) end
    if frame == 360 then drive("1 player start", true) end
    if frame == 364 then drive("1 player start", false) end
    if frame == 600 then drive("p1 right", true) end
    if frame == 660 then drive("p1 button 1", true) end
    if frame == 664 then drive("p1 button 1", false) end
    if frame == 780 then drive("p1 right", false) end
    if frame == 900 then report("gameplay") end
end, "s32_holo_palw2")
