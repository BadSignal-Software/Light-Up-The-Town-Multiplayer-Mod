-- LUTTNet v0.3 - online multiplayer prototype for Light Up The Town (UE4SS Lua)
-- Syncs: decoration place / edit / delete / swap, plus a puppet for the remote player.
-- Transport: appends lines to luttnet_out.txt, polls luttnet_in.txt (bridge.py moves them over TCP).

local UEHelpers = require("UEHelpers")

local CFG = {
    out_file       = "luttnet_out.txt",
    in_file        = "luttnet_in.txt",
    puppet_class   = "/Game/AI/Character_Holly.Character_Holly_C",
    send_particles = false,   -- cable particle positions; try true once the basics work
    sync_swap      = true,    -- replicate SwapDecoration (style/type change)
    tick_ms        = 33,      -- main loop (puppet smoothing); inbox + position every 3rd tick
}

local MGR = "/Game/Blueprints/DecorationManager/BP_DecorationManager.BP_DecorationManager_C"

-- Struct_DecorationSaveInfo field names (taken from StructDump.txt)
local F = {
    guid   = "GUID_40_8CEB54CB4370901697C12EAAA5622738",
    class  = "Class_38_07E9BBC945681DD2B30A67AE86A668A3",
    start  = "StartTransform_54_CA43A55D4AB4AEE8AFACFE94C75A2249",
    endloc = "EndLocation_34_CD0BDC6340F777CA608C0DADC3997CFE",
    len    = "Length_32_96952E8A4D0D5866C7999080E30C3710",
    parent = "ParentDecoration_28_E4A99FBE4819F4C06E8E20A8712D0013",
    style  = "DecStyleInfo_48_20810CE44AA9DB54BD391792181AC115",
    part   = "ParticlePositions_58_28DA0FB54E7A5EA37BE327BA13DD364A",
    -- ActorRef (local only) and UserAttacherAdjustment (map, TODO) are not synced yet
}

local connected = false
local applying  = false      -- true while we replay a remote change (stops echo)
local lastCore  = {}         -- guid string -> last serialized state (diff filter)
local suppress  = {}         -- guid string -> os.clock() until which local events are ignored
local queue     = {}         -- inbound lines waiting for the game thread
local inOffset  = 0
local puppet, target = nil, nil
local pawnCache = nil

local function log(fmt, ...) print(string.format("[LUTTNet] " .. fmt .. "\n", ...)) end

---------------------------------------------------------------- helpers
local function send(line)
    if not connected then return end
    local f = io.open(CFG.out_file, "a")
    if f then f:write(line, "\n"); f:close() end
end

local function guidStr(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end

local function parseGuid(s)
    local a, b, c, d = s:match("^(-?%d+):(-?%d+):(-?%d+):(-?%d+)$")
    return { A = tonumber(a) or 0, B = tonumber(b) or 0, C = tonumber(c) or 0, D = tonumber(d) or 0 }
end

local function num(x) return string.format("%.3f", x or 0) end

local function objPath(o)
    if o == nil then return "-" end
    local ok, res = pcall(function()
        if not o:IsValid() then return "-" end
        local n = o:GetFullName()
        return n:match("^%S+%s+(.+)$") or n
    end)
    return ok and res or "-"
end

local function findObj(path)
    if not path or path == "-" then return nil end
    local ok, o = pcall(StaticFindObject, path)
    if ok and o and o:IsValid() then return o end
    if LoadAsset then
        pcall(LoadAsset, (path:gsub("_C$", "")))
        ok, o = pcall(StaticFindObject, path)
        if ok and o and o:IsValid() then return o end
    end
    return nil
end

local function getMgr()
    local list = FindAllOf("BP_DecorationManager_C")
    if list then
        for _, m in ipairs(list) do
            if m:IsValid() and m:GetFName():ToString():sub(1, 9) ~= "Default__" then return m end
        end
    end
    return nil
end

local function getPawn()
    if pawnCache and pawnCache:IsValid() then return pawnCache end
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local p = pc:K2_GetPawn()
        if p and p:IsValid() then pawnCache = p; return p end
    end
    return nil
end

---------------------------------------------------------------- (de)serialization
-- core = guid, class, 10 transform numbers, 3 end-location numbers, length, parent guid, style path
local function core_of(info, g)
    local t = info[F.start]
    local r, p, s = t.Rotation, t.Translation, t.Scale3D
    local e = info[F.endloc]
    return table.concat({
        g, objPath(info[F.class]),
        num(r.X), num(r.Y), num(r.Z), num(r.W),
        num(p.X), num(p.Y), num(p.Z),
        num(s.X), num(s.Y), num(s.Z),
        num(e.X), num(e.Y), num(e.Z),
        num(info[F.len]), guidStr(info[F.parent]), objPath(info[F.style]),
    }, "\t")
end

local function particles(info)
    if not CFG.send_particles then return "-" end
    local parts = {}
    pcall(function()
        info[F.part]:ForEach(function(_, el)
            local v = el:get()
            parts[#parts + 1] = string.format("%.1f,%.1f,%.1f", v.X, v.Y, v.Z)
        end)
    end)
    if #parts == 0 then return "-" end
    return table.concat(parts, "|")
end

local function build_info(f)
    local cls = findObj(f[2])
    if not cls then return nil, "class not found: " .. tostring(f[2]) end
    local function n(i) return tonumber(f[i]) or 0 end
    local info = {
        [F.guid]   = parseGuid(f[1]),
        [F.class]  = cls,
        [F.start]  = {
            Rotation    = { X = n(3),  Y = n(4),  Z = n(5),  W = n(6) },
            Translation = { X = n(7),  Y = n(8),  Z = n(9) },
            Scale3D     = { X = n(10), Y = n(11), Z = n(12) },
        },
        [F.endloc] = { X = n(13), Y = n(14), Z = n(15) },
        [F.len]    = n(16),
        [F.parent] = parseGuid(f[17] or "0:0:0:0"),
    }
    local style = findObj(f[18])
    if style then info[F.style] = style end
    if CFG.send_particles and f[19] and f[19] ~= "-" then
        local arr = {}
        for x, y, z in f[19]:gmatch("(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)") do
            arr[#arr + 1] = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
        end
        info[F.part] = arr
    end
    return info
end

local function short(path) return (tostring(path):match("([^%./]+)$")) or tostring(path) end

---------------------------------------------------------------- apply remote changes (game thread)
local function apply_upsert(f)
    local mgr = getMgr()
    if not mgr then return log("upsert dropped: no decoration manager (not in a level?)") end
    local g = f[1]
    local core = table.concat(f, "\t", 1, 18)
    if lastCore[g] == core then return end
    local info, err = build_info(f)
    if not info then return log("upsert skipped: %s", err) end

    applying = true
    local ok, e = pcall(function()
        if lastCore[g] then mgr:DestroyDecoration(parseGuid(g), true) end
        mgr:CreateDecorationFromSaveInfo(parseGuid(g), info)
    end)
    applying = false
    lastCore[g] = core
    suppress[g] = os.clock() + 2.0
    if ok then log("<- U %s %s", g, short(f[2])) else log("apply upsert failed: %s", tostring(e)) end
end

local function apply_destroy(g)
    local mgr = getMgr()
    if not mgr then return end
    applying = true
    local ok, e = pcall(function() mgr:DestroyDecoration(parseGuid(g), true) end)
    applying = false
    lastCore[g] = nil
    suppress[g] = os.clock() + 2.0
    if ok then log("<- D %s", g) else log("apply destroy failed: %s", tostring(e)) end
end

---------------------------------------------------------------- outbound hooks
local function on_update(self, guidP, infoP)
    if applying then return end
    local ok, err = pcall(function()
        local g = guidStr(guidP:get())
        if suppress[g] and os.clock() < suppress[g] then return end
        local info = infoP:get()
        local core = core_of(info, g)
        if lastCore[g] == core then return end   -- identical to what we already know (e.g. save-pass refresh)
        lastCore[g] = core
        send("U\t" .. core .. "\t" .. particles(info))
        log("-> U %s %s", g, short(objPath(info[F.class])))
    end)
    if not ok then log("UpdateDecorationInfo hook error: %s", tostring(err)) end
end

local function on_destroy(self, guidP)
    if applying then return end
    local ok, err = pcall(function()
        local g = guidStr(guidP:get())
        if suppress[g] and os.clock() < suppress[g] then return end
        lastCore[g] = nil
        send("D\t" .. g)
        log("-> D %s", g)
    end)
    if not ok then log("DestroyDecoration hook error: %s", tostring(err)) end
end

local function on_swap(self, targetP, infoP)
    if applying or not CFG.sync_swap then return end
    local ok, err = pcall(function()
        local t = guidStr(targetP:get())
        local info = infoP:get()
        local ng = guidStr(info[F.guid])
        if ng ~= t then
            lastCore[t] = nil
            send("D\t" .. t)
        end
        local core = core_of(info, ng)
        lastCore[ng] = core
        send("U\t" .. core .. "\t" .. particles(info))
        log("-> swap %s => %s %s", t, ng, short(objPath(info[F.class])))
    end)
    if not ok then log("SwapDecoration hook error: %s", tostring(err)) end
end

local hooked = {}
local function install_hooks()
    local want = {
        UpdateDecorationInfo = on_update,
        DestroyDecoration    = on_destroy,
        SwapDecoration       = on_swap,
    }
    for name, cb in pairs(want) do
        if not hooked[name] then
            local ok = pcall(RegisterHook, MGR .. ":" .. name, cb)
            if ok then hooked[name] = true; log("hooked %s", name) end
        end
    end
end

---------------------------------------------------------------- snapshot on connect
local function snapshot()
    local mgr = getMgr()
    if not mgr then return log("snapshot skipped: no manager") end
    local heldStr = nil
    local pawn = getPawn()
    if pawn then pcall(function() heldStr = guidStr(pawn.CurrentHeldDecoration) end) end

    local n = 0
    local ok, err = pcall(function()
        mgr.MasterDecorationList:ForEach(function(k, v)
            pcall(function()
                local g = guidStr(k:get())
                if g == heldStr then return end          -- don't send the item in the player's hand
                local info = v:get()
                local core = core_of(info, g)
                lastCore[g] = core
                send("U\t" .. core .. "\t" .. particles(info))
                n = n + 1
            end)
        end)
    end)
    if not ok then log("snapshot error: %s", tostring(err)) end
    log("snapshot: sent %d decorations", n)
end

---------------------------------------------------------------- puppet (remote player)
local function spawn_puppet()
    local cls = findObj(CFG.puppet_class)
    if not cls then return log("puppet class not found: %s", CFG.puppet_class) end
    local world = UEHelpers.GetWorld()
    local ok, p = pcall(function()
        return world:SpawnActor(cls, { X = target.x, Y = target.y, Z = target.z }, { Pitch = 0, Yaw = target.yaw, Roll = 0 })
    end)
    if not ok or not p or not p:IsValid() then return log("puppet spawn failed: %s", tostring(p)) end
    puppet = p
    pcall(function() local c = puppet:GetController(); if c and c:IsValid() then c:K2_DestroyActor() end end)
    pcall(function() puppet:SetActorEnableCollision(false) end)
    pcall(function() puppet.CharacterMovement:SetMovementMode(0, 0) end)
    log("puppet spawned")
end

local function remove_puppet()
    if puppet and puppet:IsValid() then pcall(function() puppet:K2_DestroyActor() end) end
    puppet, target = nil, nil
end

local function update_puppet()
    if not connected or not target then return end
    if not (puppet and puppet:IsValid()) then spawn_puppet() end
    if not (puppet and puppet:IsValid()) then return end
    pcall(function()
        local cur = puppet:K2_GetActorLocation()
        local dx, dy, dz = target.x - cur.X, target.y - cur.Y, target.z - cur.Z
        local a = (dx * dx + dy * dy + dz * dz > 1500 * 1500) and 1.0 or 0.35
        puppet:K2_SetActorLocationAndRotation(
            { X = cur.X + dx * a, Y = cur.Y + dy * a, Z = cur.Z + dz * a },
            { Pitch = 0, Yaw = target.yaw, Roll = 0 }, false, {}, true)
    end)
end

local function send_position()
    if not connected then return end
    local pawn = getPawn()
    if not pawn then return end
    pcall(function()
        local l, r = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
        send(string.format("P\t%.1f\t%.1f\t%.1f\t%.1f", l.X, l.Y, l.Z, r.Yaw))
    end)
end

---------------------------------------------------------------- inbound
local function handle(line)
    local f = {}
    for part in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = part end
    local kind = table.remove(f, 1)
    if kind == "U" then apply_upsert(f)
    elseif kind == "D" then apply_destroy(f[1])
    elseif kind == "HELLO" then connected = true; log("peer connected"); snapshot()
    elseif kind == "BYE" then connected = false; remove_puppet(); log("peer disconnected")
    end
end

local function read_inbox()
    local fh = io.open(CFG.in_file, "rb")
    if not fh then return end
    local size = fh:seek("end")
    if size < inOffset then inOffset = 0 end      -- bridge truncated the file
    if size == inOffset then fh:close(); return end
    fh:seek("set", inOffset)
    local data = fh:read("*a")
    fh:close()
    local cut = data:match(".*()\n")
    if not cut then return end
    inOffset = inOffset + cut
    for line in data:sub(1, cut):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if line:sub(1, 2) == "P\t" then
            local x, y, z, yaw = line:match("^P\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)")
            if x then target = { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw) } end
        elseif line ~= "" then
            queue[#queue + 1] = line
        end
    end
end

---------------------------------------------------------------- main loop
do  -- start reading from the end of any stale inbox
    local fh = io.open(CFG.in_file, "rb")
    if fh then inOffset = fh:seek("end"); fh:close() end
end

local tick = 0
LoopAsync(CFG.tick_ms, function()
    ExecuteInGameThread(function()
        tick = tick + 1
        if tick % 3 == 0 then read_inbox(); send_position() end
        for _ = 1, 4 do
            local line = table.remove(queue, 1)
            if not line then break end
            local ok, err = pcall(handle, line)
            if not ok then log("handle error: %s | %s", tostring(err), line:sub(1, 80)) end
        end
        update_puppet()
    end)
    return false
end)

install_hooks()
NotifyOnNewObject(MGR, function() install_hooks() end)
RegisterKeyBind(Key.F8, function() install_hooks() end)
log("loaded (F8 = retry hooks). Start bridge.py, then HELLO from the bridge begins syncing.")
