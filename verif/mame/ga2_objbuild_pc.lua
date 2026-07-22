-- Identify the V60 routine(s) that populate the char-select OBJECT records in
-- work RAM (0x2005a0, 0x200640, 0x2008c0, 0x200a00, 0x200b40 ... — populated in
-- MAME, left zero by our sim). Tap writes across 0x2005a0-0x200c00 and log the
-- writing PC + target so we find the spawn/build loop that our V60 exits early.
local cpu  = manager.machine.devices[":mainpcb:maincpu"]
local msp  = cpu.spaces["program"]
local svc  = manager.machine.ioport.ports[":mainpcb:SERVICE12_A"]
local coin  = svc.fields["Coin 1"]
local start = svc.fields["1 Player Start"]

local log = io.open("/mnt/d/Arcade/AI/s32/scratch/ga2_objbuild_pc.txt", "w")
local pcset = {}
local tap = msp:install_write_tap(0x2005a0, 0x200bff, "objbuild", function(offset, data, mask)
  local pc = cpu.state["PC"].value
  -- record, per writing PC, the low/high target addr range it touches
  local e = pcset[pc]
  if not e then e = {lo=offset, hi=offset, n=0}; pcset[pc]=e end
  if offset < e.lo then e.lo = offset end
  if offset > e.hi then e.hi = offset end
  e.n = e.n + 1
end)

local fr = 0
_G.drive = emu.add_machine_frame_notifier(function()
  fr = fr + 1
  if fr >= 300 and fr < 390 then coin:set_value(1) elseif fr == 390 then coin:set_value(0) end
  if fr >= 430 and fr < 450 then start:set_value(1) elseif fr == 450 then start:set_value(0) end
  if fr == 522 then
    -- dump PC summary sorted by write count
    local arr = {}
    for pc,e in pairs(pcset) do arr[#arr+1] = {pc=pc, e=e} end
    table.sort(arr, function(a,b) return a.e.n > b.e.n end)
    for _,x in ipairs(arr) do
      log:write(string.format("pc=%06x writes=%d range=%06x..%06x\n", x.pc, x.e.n, x.e.lo, x.e.hi))
    end
    log:close(); print("[objbuild] done, "..#arr.." unique PCs")
  end
end)
