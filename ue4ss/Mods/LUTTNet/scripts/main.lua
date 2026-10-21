-- LUTTNet v0.1 - online multiplayer prototype for Light Up The Town (UE4SS Lua)
-- Syncs: decoration place / edit / delete / swap, plus a puppet for the remote player.
-- Transport: appends lines to luttnet_out.txt, polls luttnet_in.txt (bridge.py moves them over TCP).

local UEHelpers = require("UEHelpers")

-- Files live next to the mod (Mods/LUTTNet/), found from this script's own path,
-- so they don't depend on the game's working directory.
local function script_dir()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        src = src:gsub("^@", ""):gsub("\\", "/")
        local dir = src:match("^(.*)/[Ss]cripts/[^/]*$") or src:match("^(.*)/[^/]*$")
        if dir then return dir .. "/" end
    end
    return ""
end
local BASE = script_dir()

local CFG = {
    out_file       = BASE .. "luttnet_out.txt",
    in_file        = BASE .. "luttnet_in.txt",
    puppet_class   = "/Game/Blueprints/BP_HolidayCharacter.BP_HolidayCharacter_C",
    send_particles = true,    -- cable shape; if applying a cable fails the mod retries without it
    sync_swap      = true,    -- replicate SwapDecoration (style/type change)
    enable_puppet      = true,   -- show the other player (set false to test if the puppet causes crashes)
    puppet_delay       = 3.0,    -- seconds after connecting before the puppet is spawned
    enable_decorations = true,   -- apply decoration changes from the other player (false = positions only)
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
local connectedAt = 0
local on_tick   -- defined near the bottom; driven by the game thread, see install_hooks
local applying  = false      -- true while we replay a remote change (stops echo)
local lastCore  = {}         -- guid string -> last serialized state (diff filter)
local suppress  = {}         -- guid string -> os.clock() until which local events are ignored
local queue     = {}         -- inbound lines waiting for the game thread
local inOffset  = 0
local puppet, target = nil, nil
local pawnCache = nil

local function log(fmt, ...) print(string.format("[LUTTNet] " .. fmt .. "\n", ...)) end
local function vlog(...) if connected then log(...) end end

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

-- Compare two serialized cores while ignoring scale and cable length: the game reports
-- those differently after a decoration is re-created (e.g. scale 0.7 vs 1.0), which made
-- every periodic refresh look like a change and caused endless destroy/recreate loops.
local function split_tab(str)
    local t = {}
    for part in (str .. "\t"):gmatch("(.-)\t") do t[#t + 1] = part end
    return t
end

local function similar(a, b)
    if a == b then return true end
    if not a or not b then return false end
    local fa, fb = split_tab(a), split_tab(b)
    if #fa ~= #fb then return false end
    if fa[1] ~= fb[1] or fa[2] ~= fb[2] or fa[17] ~= fb[17] or fa[18] ~= fb[18] then return false end
    local function close(i, tol) return math.abs((tonumber(fa[i]) or 0) - (tonumber(fb[i]) or 0)) <= tol end
    for i = 3, 6 do if not close(i, 0.01) then return false end end    -- rotation
    for i = 7, 9 do if not close(i, 1.0) then return false end end     -- translation
    for i = 13, 15 do if not close(i, 1.0) then return false end end   -- end location
    return true
end

-- The game periodically calls UpdateDecorationInfo for ~100 decorations within milliseconds.
-- A player never produces that many real edits, so a flood like that is ignored.
local recentCalls, bulkUntil = {}, 0
local function is_bulk()
    local now = os.clock()
    recentCalls[#recentCalls + 1] = now
    while recentCalls[1] and now - recentCalls[1] > 0.5 do table.remove(recentCalls, 1) end
    if #recentCalls > 8 then
        if now > bulkUntil then log("bulk refresh from the game detected - ignoring it") end
        bulkUntil = now + 1.0
    end
    return now < bulkUntil
end

---------------------------------------------------------------- apply remote changes (game thread)
local ZERO_GUID = "0:0:0:0"
local cache   = {}   -- guid -> last known fields (18 strings) of every decoration we know about
local pending = {}   -- guid -> { f = fields, due = clock, giveup = clock } waiting to be applied

local function descendants(g, out, depth)
    out = out or {}
    depth = depth or 0
    if depth > 30 then return out end
    for cg, fields in pairs(cache) do
        if fields[17] == g and cg ~= g then
            out[#out + 1] = cg
            descendants(cg, out, depth + 1)
        end
    end
    return out
end

local function create_from_fields(mgr, f)
    local info, err = build_info(f)
    if not info then log("upsert skipped: %s", err); return false end
    local ok, e = pcall(function() mgr:CreateDecorationFromSaveInfo(parseGuid(f[1]), info) end)
    if not ok and info[F.part] then
        log("create with particles failed (%s) - retrying without", tostring(e))
        info[F.part] = nil
        ok, e = pcall(function() mgr:CreateDecorationFromSaveInfo(parseGuid(f[1]), info) end)
    end
    if not ok then log("create failed: %s", tostring(e)) end
    return ok
end

local function apply_upsert(f)
    local mgr = getMgr()
    if not mgr then return log("upsert dropped: no decoration manager (not in a level?)") end
    local g = f[1]
    local core = table.concat(f, "\t", 1, 18)
    if similar(lastCore[g], core) then return end

    applying = true
    local ok, e = pcall(function()
        local kids = {}
        if lastCore[g] then
            -- replacing a decoration that has children (cable chains): take the children out first,
            -- so nothing is left pointing at a destroyed parent, then rebuild them parent-first.
            kids = descendants(g)
            for i = #kids, 1, -1 do mgr:DestroyDecoration(parseGuid(kids[i]), true) end
            mgr:DestroyDecoration(parseGuid(g), true)
        end
        create_from_fields(mgr, f)
        local until_ = os.clock() + 2.0
        suppress[g] = until_
        for _, cg in ipairs(kids) do
            suppress[cg] = until_
            local cf = cache[cg]
            if cf then create_from_fields(mgr, cf) end
        end
        if #kids > 0 then log("rebuilt %d child decoration(s) of %s", #kids, g) end
    end)
    applying = false
    lastCore[g] = core
    cache[g] = f
    suppress[g] = os.clock() + 2.0
    if ok then log("<- U %s %s", g, short(f[2])) else log("apply upsert failed: %s", tostring(e)) end
end

local function apply_destroy(g)
    pending[g] = nil
    local mgr = getMgr()
    if not mgr then return end
    applying = true
    local ok, e = pcall(function() mgr:DestroyDecoration(parseGuid(g), true) end)
    applying = false
    lastCore[g] = nil
    cache[g] = nil
    suppress[g] = os.clock() + 2.0
    if ok then log("<- D %s", g) else log("apply destroy failed: %s", tostring(e)) end
end

-- Remote updates are queued: cables are held briefly so rapid edits collapse into one change,
-- and a decoration waits for its parent to exist before it is created.
local function queue_upsert(f)
    local g = f[1]
    local now = os.clock()
    local old = pending[g]
    local isCable = f[2] and f[2]:find("Cable", 1, true)
    pending[g] = { f = f, due = now + (isCable and 0.7 or 0.0), giveup = old and old.giveup or (now + 6.0) }
end

local function process_pending(maxN)
    local now, done = os.clock(), 0
    for g, p in pairs(pending) do
        if done >= maxN then break end
        if now >= p.due then
            local par = p.f[17]
            local ready = (par == nil) or (par == ZERO_GUID) or (lastCore[par] ~= nil)
            if ready or now >= p.giveup then
                if not ready then
                    log("parent %s of %s never arrived - creating without it", par, g)
                    p.f[17] = ZERO_GUID
                end
                pending[g] = nil
                apply_upsert(p.f)
                done = done + 1
            end
        end
    end
end

---------------------------------------------------------------- outbound hooks
-- v0.5: the hooks no longer read the game's parameter structs. A crash dump showed an access
-- violation inside UE4SS while one of our hook callbacks read a struct passed by the game.
-- Now a hook only notes WHICH decoration (4 integers) changed; the real data is read a moment
-- later, from the decoration manager's own list, outside the game's function call.
local dirty = {}

local function mark_dirty(self, guidP)
    if applying then return end
    if is_bulk() then return end
    local ok, g = pcall(function() return guidStr(guidP:get()) end)
    if not ok then return end
    local sup = suppress[g]
    if sup and os.clock() < sup then return end
    dirty[g] = os.clock()
end

local function flush_dirty()
    if next(dirty) == nil then return end
    local now = os.clock()
    local ready, any = {}, false
    for g, t in pairs(dirty) do
        if now - t >= 0.25 then ready[g] = true; any = true end
    end
    if not any then return end
    for g in pairs(ready) do dirty[g] = nil end
    local mgr = getMgr()
    if not mgr then return end

    local found = {}
    local ok, err = pcall(function()
        mgr.MasterDecorationList:ForEach(function(k, v)
            pcall(function()
                local g = guidStr(k:get())
                if not ready[g] then return end
                local info = v:get()
                local core = core_of(info, g)
                found[g] = { core = core, line = "U\t" .. core .. "\t" .. particles(info) }
            end)
        end)
    end)
    if not ok then return log("flush error: %s", tostring(err)) end

    for g in pairs(ready) do
        local e = found[g]
        if e then
            if not similar(lastCore[g], e.core) then
                lastCore[g] = e.core
                cache[g] = split_tab(e.core)
                send(e.line)
                vlog("-> U %s %s", g, short(split_tab(e.core)[2]))
            end
        elseif connected or lastCore[g] then   -- no longer in the list: it was deleted
            lastCore[g] = nil
            cache[g] = nil
            send("D\t" .. g)
            vlog("-> D %s", g)
        end
    end
end

local hooked = {}
local function install_hooks()
    local want = {
        UpdateDecorationInfo = mark_dirty,
        DestroyDecoration    = mark_dirty,
        SwapDecoration       = mark_dirty,
        ReceiveTick          = function() if on_tick then on_tick() end end,   -- runs every frame on the game thread
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

    local entries = {}
    local ok, err = pcall(function()
        mgr.MasterDecorationList:ForEach(function(k, v)
            pcall(function()
                local g = guidStr(k:get())
                if g == heldStr then return end          -- don't send the item in the player's hand
                local info = v:get()
                local core = core_of(info, g)
                lastCore[g] = core
                cache[g] = split_tab(core)
                entries[#entries + 1] = { g = g, parent = guidStr(info[F.parent]),
                                          line = "U\t" .. core .. "\t" .. particles(info) }
            end)
        end)
    end)
    if not ok then log("snapshot error: %s", tostring(err)) end

    -- send parents before children so the other side can attach them correctly
    local byG = {}
    for _, e in ipairs(entries) do byG[e.g] = e end
    local function depth(e, d)
        local par = byG[e.parent]
        if not par or d > 30 then return d end
        return depth(par, d + 1)
    end
    for _, e in ipairs(entries) do e.depth = depth(e, 0) end
    table.sort(entries, function(x, y)
        if x.depth ~= y.depth then return x.depth < y.depth end
        return x.g < y.g
    end)
    for _, e in ipairs(entries) do send(e.line) end
    log("snapshot: sent %d decorations", #entries)
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
    if not CFG.enable_puppet then return end
    if not connected or not target then return end
    if os.clock() - (target.t or 0) > 5 then remove_puppet(); log("peer stopped sending positions - puppet removed"); return end
    if not (puppet and puppet:IsValid()) then
        if os.clock() - connectedAt < CFG.puppet_delay then return end
        spawn_puppet()
    end
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
    if kind == "U" then if CFG.enable_decorations then queue_upsert(f) end
    elseif kind == "D" then if CFG.enable_decorations then apply_destroy(f[1]) end
    elseif kind == "HELLO" then connected = true; connectedAt = os.clock(); log("peer connected"); snapshot()
    elseif kind == "BYE" then connected = false; remove_puppet(); log("peer disconnected")
    end
end

local inboxCount = 0
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
            if x then target = { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), t = os.clock() } end
        elseif line ~= "" then
            queue[#queue + 1] = line
        end
        inboxCount = inboxCount + 1
        if inboxCount == 1 or inboxCount % 100 == 0 then
            log("inbox: %d lines read so far (queue %d, connected=%s)", inboxCount, #queue, tostring(connected))
        end
    end
end

---------------------------------------------------------------- main loop
do  -- start reading from the end of any stale inbox
    local fh = io.open(CFG.in_file, "rb")
    if fh then inOffset = fh:seek("end"); fh:close() end
end

local wantDump = false
local function dump_functions()
    local C = "/Game/Blueprints/Cables/BP_Decoration_Cable.BP_Decoration_Cable_C:"
    local D = "/Game/Blueprints/Decorations/BP_Decoration.BP_Decoration_C:"
    local targets = {
        C .. "ApplySaveInfo", C .. "AttachToWorldHit", C .. "AttachtoEndSphere", C .. "SetAttachmentFinalized",
        C .. "SetCableAsleep", C .. "ForceSetAsleep", C .. "LoadBehavior", C .. "ChildAttached", C .. "SetUpFromDecorationInfo",
        C .. "ApplyDecorationSaveInfo", C .. "UpdateDecorationInfoInManager",
        D .. "AttachDecToWorldHit", D .. "SetAttachmentFinalized", D .. "LoadBehavior", D .. "SetUpFromDecorationInfo",
        D .. "ApplyDecorationSaveInfo", D .. "OverrideSaveInfo", D .. "GetSaveInfo", D .. "ForceHit", D .. "ApplyUserAdjustment",
        MGR .. ":CreateDecorationFromSaveInfo", MGR .. ":SpawnAndRegisterDecorationV2",
    }
    local out = {}
    local function tname(pr) return pr:GetClass():GetFName():ToString() end
    local function walk(st, indent, depth)
        st:ForEachProperty(function(pr)
            local t = tname(pr)
            local line = indent .. pr:GetFName():ToString() .. " : " .. t
            if t == "StructProperty" then
                local ok, inner = pcall(function() return pr:GetStruct() end)
                if ok and inner then
                    out[#out + 1] = line .. " <" .. inner:GetFName():ToString() .. ">"
                    if depth < 2 then walk(inner, indent .. "    ", depth + 1) end
                    return
                end
            end
            out[#out + 1] = line
        end)
    end
    for _, path in ipairs(targets) do
        out[#out + 1] = "=== " .. path
        local ok, obj = pcall(StaticFindObject, path)
        if ok and obj and obj:IsValid() then
            local ok2, e = pcall(walk, obj, "  ", 0)
            if not ok2 then out[#out + 1] = "  ERROR: " .. tostring(e) end
        else
            out[#out + 1] = "  NOT FOUND"
        end
    end
    local fh = io.open(BASE .. "FunctionDump.txt", "w")
    if fh then fh:write(table.concat(out, "\n")); fh:close() end
    log("F7: wrote FunctionDump.txt (%d lines) to %s", #out, BASE)
end
RegisterKeyBind(Key.F7, function() wantDump = true end)   -- executed on the next game-thread tick

local tick, lastErr, lastTickAt = 0, "", 0
on_tick = function()
    local now = os.clock()
    if now - lastTickAt < CFG.tick_ms / 1000 then return end
    lastTickAt = now
    tick = tick + 1
    if tick == 1 then log("main loop running (game-thread tick); inbox = %s", CFG.in_file) end
    if wantDump then wantDump = false; pcall(dump_functions) end
    local ok, err = pcall(function()
        if tick % 3 == 0 then read_inbox(); send_position(); flush_dirty() end
        for _ = 1, 20 do
            local line = table.remove(queue, 1)
            if not line then break end
            local ok2, err2 = pcall(handle, line)
            if not ok2 then log("handle error: %s | %s", tostring(err2), line:sub(1, 80)) end
        end
        process_pending(2)
        update_puppet()
    end)
    if not ok and tostring(err) ~= lastErr then lastErr = tostring(err); log("tick error: %s", lastErr) end
end

install_hooks()
NotifyOnNewObject(MGR, function() install_hooks() end)
RegisterKeyBind(Key.F8, function() install_hooks() end)
log("loaded v0.6 on machine %s. Files folder: %s", tostring(os.getenv("COMPUTERNAME") or "?"), BASE ~= "" and BASE or "(game working dir)")
