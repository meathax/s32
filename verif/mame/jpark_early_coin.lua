-- Prove the earliest safe coin timing used by the Verilator ROM-boot test.
local machine = manager.machine
local cpu = machine.devices[":mainpcb:maincpu"]
local mem = cpu.spaces["program"]
local coin = machine.ioport.ports[":mainpcb:SERVICE12_A"].fields["Coin 1"]
local frame = 0

local function draw_count()
    local entry, count = 0, 0
    for _ = 1, 8192 do
        local base = 0x400000 + entry * 16
        local word0 = mem:read_u16(base)
        local command = word0 >> 14
        if command == 3 then return count end
        if command == 2 then
            entry = word0 & 0x1fff
        else
            if command == 0 then
                local word1 = mem:read_u16(base + 2)
                local word2 = mem:read_u16(base + 4)
                local word3 = mem:read_u16(base + 6)
                local bpp8 = (word0 & 0x0200) ~= 0
                local srcw = bpp8 and (word1 & 0x3f) or ((word1 >> 1) & 0x3f)
                if srcw ~= 0 and (word1 >> 8) ~= 0 and
                   (word2 & 0x03ff) ~= 0 and (word3 & 0x03ff) ~= 0 then
                    count = count + 1
                end
            end
            entry = (entry + 1) & 0x1fff
        end
    end
    return count
end

_G.jpark_early_coin_frames = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    coin:set_value(frame >= 20 and frame <= 24 and 1 or 0)
    local draws = draw_count()
    if draws ~= 0 then
        print(string.format("JPEARLY first_draw_frame=%d draws=%d", frame, draws))
        machine:exit()
    elseif frame == 70 then
        print("JPEARLY no draws by frame 70")
        machine:exit()
    end
end)
