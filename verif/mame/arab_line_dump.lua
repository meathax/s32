-- Arabian Fight: snapshot the "Press Start" attract screen and dump the
-- per-line tilemap scroll/rowscroll/rowselect state plus the mixer registers
-- at that frame, for comparison against the FPGA core's line pipeline.
local mac = manager.machine
local out = os.getenv("ARAB_LINE_OUT") or "arab_line_dump.txt"
local frames = {}
for f in string.gmatch(os.getenv("ARAB_LINE_FRAMES") or "1200", "[^,]+") do
    frames[tonumber(f)] = true
end

local coin = nil
for _, port in pairs(mac.ioport.ports) do
    for name, field in pairs(port.fields) do
        if name == "Coin 1" then coin = field end
    end
end

local fh = io.open(out, "w")
local prog = mac.devices[":mainpcb:maincpu"].spaces["program"]

local VRAM = 0x300000       -- tilemap VRAM base
local SCROLL = 0x31ff00     -- scroll/tilemap control registers

local function rd16(a) return prog:read_u16(a) end

local function dump(n)
    fh:write(string.format("FRAME %d\n", n))
    for i = 0, 0x5f, 2 do
        fh:write(string.format("  ctrl %04x = %04x\n", 0x1ff00 + i, rd16(SCROLL + i)))
    end
    -- rowscroll/rowselect tables: base = ((ctrl[0x04] >> 10) & 0x3f) * 0x400
    -- words inside VRAM; NBG3 is +0x100 words, rowselect is +0x200 words.
    local c4 = rd16(SCROLL + 0x04)
    local tb = VRAM + (((c4 >> 10) & 0x3f) * 0x400) * 2
    fh:write(string.format("  tablebase %06x ctrl04 %04x\n", tb, c4))
    for _, off in ipairs({0, 0x100, 0x200, 0x300}) do
        fh:write(string.format("  tab +%03x:", off))
        for line = 0, 223 do
            fh:write(string.format(" %04x", rd16(tb + (off + line) * 2)))
        end
        fh:write("\n")
    end
    fh:flush()
end

local n = 0
_G.__tap = emu.add_machine_frame_notifier(function()
    n = n + 1
    if coin then
        if (n >= 120 and n <= 126) or (n >= 160 and n <= 166) or
           (n >= 200 and n <= 206) or (n >= 240 and n <= 246) then
            coin:set_value(1)
        else
            coin:set_value(0)
        end
    end
    if frames[n] then
        mac.video:snapshot()
        dump(n)
        print(string.format("SNAP frame=%d", n))
    end
end)
