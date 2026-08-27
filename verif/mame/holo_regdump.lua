-- Holosseum video-register/palette ground-truth dump for the RTL audit.
-- Dumps at title screen (frame 240), post-coin (420) and gameplay (900):
--   * mixer registers 0x610000-0x61007F (64 words)
--   * videoram controls 0x31FF00-0x31FF0E and 0x31FF5C/0x31FF5E, 0x31FF8E
--   * full palette bank 0 native view 0x600000-0x607FFF (0x4000 words)
-- Output: one file per frame in the directory from $S32_DUMP_DIR.

local machine = manager.machine
local dumpdir = os.getenv("S32_DUMP_DIR") or "."
local frame = 0
local fields = {}

local function space()
    local dev = machine.devices[":mainpcb:maincpu"] or machine.devices[":maincpu"]
    return dev.spaces["program"]
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
            return field
        end
    end
    return nil
end

local function drive(pattern, active)
    local field = find_field(pattern)
    if field then field:set_value(active and 1 or 0) end
end

local function dump(tag)
    local mem = space()
    local path = string.format("%s/regdump-%04d-%s.txt", dumpdir, frame, tag)
    local f = assert(io.open(path, "w"))
    f:write(string.format("# holo frame %d (%s)\n", frame, tag))

    f:write("MIXER0:")
    for i = 0, 63 do
        f:write(string.format(" %04x", mem:read_u16(0x610000 + i * 2)))
    end
    f:write("\n")

    f:write("VCTRL:")
    for _, a in ipairs({0x31ff00, 0x31ff02, 0x31ff04, 0x31ff06,
                        0x31ff0c, 0x31ff0e, 0x31ff5c, 0x31ff5e, 0x31ff8e}) do
        f:write(string.format(" %06x=%04x", a, mem:read_u16(a)))
    end
    f:write("\n")

    f:write("SPRCTL_MIX_4C_4E:")
    f:write(string.format(" 4c=%04x 4e=%04x 3e=%04x 2c=%04x\n",
        mem:read_u16(0x61004c), mem:read_u16(0x61004e),
        mem:read_u16(0x61003e), mem:read_u16(0x61002c)))

    f:write("PALETTE0 native (16 words per line, word index hex):\n")
    for base = 0, 0x3fff, 16 do
        f:write(string.format("%04x:", base))
        for i = 0, 15 do
            f:write(string.format(" %04x", mem:read_u16(0x600000 + (base + i) * 2)))
        end
        f:write("\n")
    end
    f:close()
    print(string.format("S32_DUMP done frame=%d tag=%s", frame, tag))
end

remember_fields()

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 240 then dump("attract-title") end
    if frame == 300 then drive("coin 1", true) end
    if frame == 304 then drive("coin 1", false) end
    if frame == 360 then drive("1 player start", true) end
    if frame == 364 then drive("1 player start", false) end
    if frame == 420 then dump("post-start") end
    if frame == 600 then drive("p1 right", true) end
    if frame == 660 then drive("p1 button 1", true) end
    if frame == 664 then drive("p1 button 1", false) end
    if frame == 780 then drive("p1 right", false) end
    if frame == 900 then
        dump("gameplay")
        machine.video:snapshot()
    end
end, "s32_holo_regdump")
