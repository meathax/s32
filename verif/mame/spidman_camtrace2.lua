-- spidman phase-2: (a) hex-dump the camera-copy maintainer routines for
-- offline V60 disassembly, (b) read-tap the copy block to find the spawn
-- gates (the PCs that CONSUME the world position), (c) log the first few
-- distinct read PCs with the value they read.
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]

local frame = 0
local readers = {}

_G.cam_rtap = mem:install_read_tap(0x208300, 0x20835F, "cam_reads",
    function(offset, data, mask)
        local pc = cpu.state["PC"].value
        local key = string.format("%06X->%06X", pc, offset)
        readers[key] = (readers[key] or 0) + 1
    end)

local function dump(base, len, tag)
    for a = base, base + len - 1, 16 do
        local s = {}
        for i = 0, 15 do s[#s+1] = string.format("%02x", mem:read_u8(a + i)) end
        print(string.format("DUMP %s %06X: %s", tag, a, table.concat(s, " ")))
    end
end

_G.cam_notifier2 = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    if frame == 300 then
        dump(0x085200, 0x200, "W852")   -- writers 0x852E2/E8 + gate context
        dump(0x086900, 0x1C0, "W869")   -- writers 0x8698A/90
        dump(0x086C00, 0x100, "W86C")   -- stepped writer 0x86C4B
        dump(0x060880, 0x100, "INIT")   -- init/clear loop area
    end
end)

emu.register_stop(function()
    print("CAMREADERS begin")
    local sorted = {}
    for k, v in pairs(readers) do sorted[#sorted+1] = {k, v} end
    table.sort(sorted, function(a, b) return a[2] > b[2] end)
    for i, kv in ipairs(sorted) do
        if i <= 60 then print(string.format("CAMREADER %s x%d", kv[1], kv[2])) end
    end
    print("CAMREADERS end")
end)
