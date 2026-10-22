-- LUTTNet v0.8 - online multiplayer prototype for Light Up The Town (UE4SS Lua)
-- Syncs: decoration place / edit / delete / swap, plus a puppet for the remote player.
-- Transport: appends lines to luttnet_out.txt, polls luttnet_in.txt (bridge.py moves them over TCP).

local UEHelpers = require("UEHelpers")
local cableQueue = {}        -- guid -> { info = info, due = clock, tries = n }
local spawnRetryQueue = {}   -- guid -> { fields = f, due = clock, tries = n }

-- Handles sagging curves and particle positions for cables/lights
local function apply_cable_particles()
    if next(cableQueue) == nil then return end
    local now, due, any = os.clock(), {}, false
    for g, a in pairs(cableQueue) do
        if now >= a.due then due[g] = a; any = true end
    end
    if not any then return end
    local mgr = getMgr()
    if not mgr or not pcall(function() return mgr:IsValid() end) or not mgr:IsValid() then return end

    local actors = {}
    pcall(function()
        if not mgr.MasterDecorationList then return end
        mgr.MasterDecorationList:ForEach(function(k, v)
            pcall(function()
                if not k or not v then return end
                local k_val = k:get()
                local v_val = v:get()
                if not k_val or not v_val then return end
                
                local g = guidStr(k_val)
                if not due[g] then return end
                
                local a = v_val[F.actor]
                if a and type(a.IsValid) == "function" and a:IsValid() then
                    actors[g] = a
                end
            end)
        end)
    end)

    for g, a in pairs(due) do
        local actor = actors[g]
        if actor then
            cableQueue[g] = nil
            pcall(function()
                if actor:IsValid() then
                    actor:ApplySaveInfo(a.info)
                    log("Successfully applied particle positions to cable %s", g)
                end
            end)
        else
            a.tries = a.tries + 1
            a.due = now + 0.5 
            if a.tries > 8 then 
                cableQueue[g] = nil 
                log("Actor not found for cable %s - particle apply dropped safely", g) 
            end
        end
    end
end

-- Retries spawning decorations if the world/manager wasn't ready yet (fixes peer visibility)
local function process_spawn_retries()
    if next(spawnRetryQueue) == nil then return end
    local now = os.clock()
    local mgr = getMgr()
    if not mgr or not pcall(function() return mgr:IsValid() end) or not mgr:IsValid() then return end
    
    for g, data in pairs(spawnRetryQueue) do
        if now >= data.due then
            spawnRetryQueue[g] = nil
            create_from_fields(mgr, data.fields)
        end
    end
end

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
    sync_animation = true,    -- walk/run animation on the other player's puppet (needs the sender to run v0.7 for exact speed)
    sync_held_item = true,    -- master switch for held-item sync (what the other player carries)
    held_send      = true,    -- this machine tells the other player what it is holding
    held_show      = true,    -- this machine shows what the other player is holding
    held_trace     = true,    -- crash breadcrumbs: if the game dies inside a held-item step, the next launch turns that side off
    debug_anim     = true,    -- log puppet speed about once a second (set false once animations work)
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
    adj    = "UserAttacherAdjustment_52_5C8A6E224C39074EB2A2AB9321504D81",   -- Map<Enum_UserAdjustmentType, Struct_AdjustmentRawData>
    actor  = "ActorRef_30_1628099C45F5C07BEFA560915FF694C4",                -- local-only, read from the master list
}

-- Struct_AdjustmentRawData fields
local RAW = {
    float = "Float_2_DA197CAF4A187BB48BD912BC360C6031",
    bool  = "Bool_7_73560D444D3C409A0210D787351F6211",
    int   = "Int_9_B28930C54F77003ADE54918A464B77AD",
    vec   = "Vector_14_27032DEB4BDE64E9033F9487B2311D74",
    valid = "Validated_16_80D10EDF415EA41371A2D09FF70FC626",
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
local function adj_of(info)
    local parts = {}
    pcall(function()
        info[F.adj]:ForEach(function(k, v)
            pcall(function()
                local t, r = k:get(), v:get()
                local vec = r[RAW.vec]
                parts[#parts + 1] = string.format("%d:%.4f:%d:%d:%.3f:%.3f:%.3f:%d",
                    t, r[RAW.float] or 0, r[RAW.bool] and 1 or 0, r[RAW.int] or 0,
                    vec.X, vec.Y, vec.Z, r[RAW.valid] and 1 or 0)
            end)
        end)
    end)
    if #parts == 0 then return "-" end
    table.sort(parts)
    return table.concat(parts, "|")
end

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
        adj_of(info),
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
    if CFG.send_particles and f[20] and f[20] ~= "-" then
        local arr = {}
        for x, y, z in f[20]:gmatch("(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)") do
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
    if fa[1] ~= fb[1] or fa[2] ~= fb[2] or fa[17] ~= fb[17] or fa[18] ~= fb[18] or fa[19] ~= fb[19] then return false end
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
local adjQueue = {}   -- guid -> { list = {...}, due = clock, tries = n }

local function queue_adj(g, str)
    if not str or str == "-" then return end
    local list = {}
    for item in str:gmatch("[^|]+") do
        local t, fl, b, i, x, y, z, v = item:match("^(%-?%d+):(%-?[%d%.]+):(%d):(%-?%d+):(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+):(%d)$")
        if t then
            list[#list + 1] = { type = tonumber(t), float = tonumber(fl), bool = b == "1", int = tonumber(i),
                                x = tonumber(x), y = tonumber(y), z = tonumber(z), valid = v == "1" }
        end
    end
    if #list > 0 then adjQueue[g] = { list = list, due = os.clock() + 0.3, tries = 0 } end
end

local function apply_adjustments()
    if next(adjQueue) == nil then return end
    local now, due, any = os.clock(), {}, false
    for g, a in pairs(adjQueue) do
        if now >= a.due then due[g] = a; any = true end
    end
    if not any then return end
    local mgr = getMgr()
    if not mgr then return end
    local actors = {}
    pcall(function()
        mgr.MasterDecorationList:ForEach(function(k, v)
            pcall(function()
                local g = guidStr(k:get())
                if not due[g] then return end
                local a = v:get()[F.actor]
                if a and a:IsValid() then actors[g] = a end
            end)
        end)
    end)
    for g, a in pairs(due) do
        local actor = actors[g]
        if actor then
            adjQueue[g] = nil
            applying = true
            local ok, e = pcall(function()
                for _, en in ipairs(a.list) do
                    actor:ApplyUserAdjustment(en.type, {
                        [RAW.float] = en.float, [RAW.bool] = en.bool, [RAW.int] = en.int,
                        [RAW.vec] = { X = en.x, Y = en.y, Z = en.z }, [RAW.valid] = en.valid,
                    }, true)
                end
            end)
            applying = false
            suppress[g] = os.clock() + 2.0
            if ok then log("applied %d adjustment(s) to %s", #a.list, g) else log("adjustments failed for %s: %s", g, tostring(e)) end
        else
            a.tries = a.tries + 1
            a.due = now + 0.3
            if a.tries > 10 then adjQueue[g] = nil; log("no actor found for %s - adjustments dropped", g) end
        end
    end
end
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
        local infoWithout = build_info(f)
        infoWithout[F.part] = nil
        ok, e = pcall(function() mgr:CreateDecorationFromSaveInfo(parseGuid(f[1]), infoWithout) end)
    end
    
    if ok then
        if info[F.part] then
            cableQueue[f[1]] = { info = info, due = os.clock() + 0.3, tries = 0 }
        end
        spawnRetryQueue[f[1]] = nil
    else
        log("create failed for %s (%s) - queueing retry", tostring(f[1]), tostring(e))
        local existing = spawnRetryQueue[f[1]] or { fields = f, tries = 0 }
        existing.tries = existing.tries + 1
        if existing.tries <= 5 then
            spawnRetryQueue[f[1]] = { fields = f, due = os.clock() + 1.0, tries = existing.tries }
        end
    end
    return ok
end

local function apply_upsert(f)
    local mgr = getMgr()
    if not mgr then return log("upsert dropped: no decoration manager (not in a level?)") end
    local g = f[1]
    local core = table.concat(f, "\t", 1, 19)
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
        queue_adj(g, f[19])
        local until_ = os.clock() + 2.0
        suppress[g] = until_
        for _, cg in ipairs(kids) do
            suppress[cg] = until_
            local cf = cache[cg]
            if cf then create_from_fields(mgr, cf); queue_adj(cg, cf[19]) end
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
        AddDecUserAdjustment = mark_dirty,
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

---------------------------------------------------------------- held item: crash breadcrumbs
-- Every risky native step of the held-item code writes "BEGIN <side>:<step>" to a file BEFORE it runs and "END"
-- after. A Lua pcall cannot catch a crash inside UE4SS, but the file survives it. If the game dies inside a step,
-- the file still says BEGIN on the next launch: that side (send / show) is then switched off automatically and
-- remembered in luttnet_held_disabled.txt, so the game keeps working and the step name says where it died.
-- Delete luttnet_held_disabled.txt to try again.
local TRACE_FILE    = BASE .. "luttnet_held_trace.txt"
local DISABLED_FILE = BASE .. "luttnet_held_disabled.txt"

local function read_all(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end

local function write_all(path, text, mode)
    local fh = io.open(path, mode or "w")
    if fh then fh:write(text); fh:close() end
end

do
    local last = read_all(TRACE_FILE) or ""
    local side, stepName = last:match("^BEGIN%s+(%a+):(%S+)")
    if side then
        write_all(DISABLED_FILE, side .. ":" .. stepName .. "\n", "a")
        log("the last run died inside held-item step '%s:%s' - that side of held item sync is now OFF", side, stepName)
    end
    local dis = read_all(DISABLED_FILE) or ""
    if dis:find("send:", 1, true) then CFG.held_send = false end
    if dis:find("show:", 1, true) then CFG.held_show = false end
    if dis ~= "" then
        log("held item: send=%s show=%s (delete luttnet_held_disabled.txt to try again)", tostring(CFG.held_send), tostring(CFG.held_show))
    end
    write_all(TRACE_FILE, "END\n", "w")
end

local function trace_begin(name)
    if CFG.held_trace then write_all(TRACE_FILE, "BEGIN " .. name .. "\n", "w") end
end

local function trace_end()
    if CFG.held_trace then write_all(TRACE_FILE, "END\n", "w") end
end

-- Runs fn inside a breadcrumb + pcall; returns whatever fn returns, or nil if it raised a Lua error.
local function step(name, fn)
    trace_begin(name)
    local res = table.pack(pcall(fn))
    trace_end()
    if res[1] then return table.unpack(res, 2, res.n) end
    return nil
end

---------------------------------------------------------------- held item: what the REMOTE player carries
local function isvalid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function class_name(o)
    local n = nil
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local heldWanted   = nil    -- { kind, mesh, sx, sy, sz, attach, socket, lx, ly, lz, rp, ry, rr } or nil = empty hands
local heldKey      = "-"
local heldVisual   = nil    -- the plain mesh actor we attach to the puppet (never a game decoration, so nothing syncs back)
local heldDirty    = false
local heldFailures = 0
local heldRetryAt  = 0
local heldBadMesh  = {}     -- mesh paths that could not be shown; never retried this session
local puppetBornAt = 0      -- when the current puppet was spawned (the item is attached a moment later)

local function destroy_held_visual()
    if heldVisual ~= nil then
        pcall(function() if heldVisual:IsValid() then heldVisual:K2_DestroyActor() end end)
    end
    heldVisual = nil
end

local ATTACH_OK = { ObjectRight = true, ObjectLeft = true, Mesh = true, CharacterMesh0 = true }

local function set_held_wanted(f)
    -- f = { kind, meshPath, sx, sy, sz, attachComponent, socket, lx, ly, lz, pitch, yaw, roll }
    -- Everything here came over the network, so it is checked before it is ever handed to the engine.
    local kind = f[1]
    local key
    if kind ~= "S" and kind ~= "K" then
        heldWanted, key = nil, "-"
    elseif type(f[2]) ~= "string" or not f[2]:match("^/[%w_/%.%-]+$") then
        heldWanted, key = nil, "-"
    else
        local function n(i, d) return tonumber(f[i]) or d end
        local function sc(i) local v = n(i, 1); if v < 0.01 then v = 0.01 elseif v > 20 then v = 20 end; return v end
        local attach = ATTACH_OK[f[6] or ""] and f[6] or "ObjectRight"
        local socket = (f[7] and f[7]:match("^[%w_%.%-]+$")) and f[7] or "None"
        heldWanted = { kind = kind, mesh = f[2], sx = sc(3), sy = sc(4), sz = sc(5),
                       attach = attach, socket = socket,
                       lx = n(8, 0), ly = n(9, 0), lz = n(10, 0), rp = n(11, 0), ry = n(12, 0), rr = n(13, 0) }
        key = table.concat({ kind, f[2], attach, socket }, "|")
    end
    if key ~= heldKey then
        heldKey = key
        heldDirty = true
        log("<- H %s", key)
    end
end

local function build_held_visual()
    destroy_held_visual()
    local w = heldWanted
    if not w or not isvalid(puppet) then return end
    if heldBadMesh[w.mesh] then return end

    -- 1) the mesh asset. It must exist locally AND be the kind of asset the sender said it is.
    local mesh = step("show:find_mesh", function() return findObj(w.mesh) end)
    if not isvalid(mesh) then
        heldBadMesh[w.mesh] = true
        log("held: mesh not found here, item skipped: %s", tostring(w.mesh))
        return
    end
    local wantClass = (w.kind == "K") and "SkeletalMesh" or "StaticMesh"
    local gotClass = class_name(mesh)
    if gotClass ~= wantClass then
        heldBadMesh[w.mesh] = true
        log("held: %s is a %s, expected a %s - item skipped", short(w.mesh), tostring(gotClass), wantClass)
        return
    end

    -- 2) a plain engine actor to carry it (never a game decoration, so nothing syncs back)
    local isSkel = (w.kind == "K")
    local cls = StaticFindObject(isSkel and "/Script/Engine.SkeletalMeshActor" or "/Script/Engine.StaticMeshActor")
    if not isvalid(cls) then log("held: engine actor class missing"); return end
    local world = UEHelpers.GetWorld()
    if not isvalid(world) then log("held: no world"); return end
    local loc = puppet:K2_GetActorLocation()
    local a = step("show:spawn", function()
        return world:SpawnActor(cls, { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not isvalid(a) then log("held: spawn failed"); return end
    heldVisual = a

    local comp = nil
    pcall(function() comp = isSkel and a.SkeletalMeshComponent or a.StaticMeshComponent end)
    if not isvalid(comp) then log("held: no mesh component on the spawned actor"); destroy_held_visual(); return end

    -- 3) mesh + look
    step("show:mesh", function()
        comp:SetMobility(2)                                   -- Movable, otherwise the mesh can't be set at runtime
        if isSkel then
            if not pcall(function() comp:SetSkeletalMesh(mesh, true) end) then
                comp:SetSkeletalMeshAsset(mesh)
            end
        else
            comp:SetStaticMesh(mesh)
        end
        comp:SetCollisionEnabled(0)
        a:SetActorEnableCollision(false)
        a:SetActorScale3D({ X = w.sx, Y = w.sy, Z = w.sz })
    end)

    -- 4) attach to the puppet. The parent must really be a component: handing an actor (or anything else)
    --    to K2_AttachToComponent is a type confusion inside the engine, and that is not catchable from Lua.
    local parent = nil
    local function try_parent(getter)
        if isvalid(parent) then return end
        local p = nil
        pcall(function() p = getter() end)
        local cn = isvalid(p) and class_name(p) or nil
        if cn and cn:find("Component", 1, true) then parent = p end
    end
    if w.attach == "CharacterMesh0" or w.attach == "Mesh" then
        try_parent(function() return puppet.Mesh end)
    else
        try_parent(function() return puppet[w.attach] end)
    end
    try_parent(function() return puppet.ObjectRight end)
    try_parent(function() return puppet.Mesh end)
    if not isvalid(parent) then log("held: nothing on the puppet to attach to"); destroy_held_visual(); return end

    -- EAttachmentRule: 0 KeepRelative, 1 KeepWorld, 2 SnapToTarget
    -- IMPORTANT: the SocketName parameter is an FName. UE4SS 3.0.1's FName parameter handler only accepts an FName
    -- userdata: a plain Lua string (or nil) makes it dereference a null pointer, which is a native crash that pcall
    -- cannot catch (this was the v0.7.1 / v0.7.2 held-item crash, UE4SS.dll+0x2cccd1). So always pass FName(...).
    local attached = step("show:attach", function()
        local sock = FName(w.socket)
        a:K2_AttachToComponent(parent, sock, 2, 2, 1, false)
        return true
    end)
    if not attached then log("held: attach failed (parent %s, socket %s)", tostring(w.attach), tostring(w.socket)); destroy_held_visual(); return end
    pcall(function() a:K2_SetActorRelativeLocation({ X = w.lx, Y = w.ly, Z = w.lz }, false, {}, true) end)
    pcall(function() a:K2_SetActorRelativeRotation({ Pitch = w.rp, Yaw = w.ry, Roll = w.rr }, false, {}, true) end)
    log("held: showing %s on %s", short(w.mesh), tostring(w.attach))
end

local function update_held_visual()
    if not (CFG.sync_held_item and CFG.held_show) then return end
    if not isvalid(puppet) then return end
    if not heldDirty then return end
    local now = os.clock()
    if now < heldRetryAt or now - puppetBornAt < 1.0 then return end   -- let the new puppet settle first
    heldDirty = false
    local ok, e = pcall(build_held_visual)
    if not ok then
        heldFailures = heldFailures + 1
        heldRetryAt = now + 2.0
        log("held visual error: %s", tostring(e))
        if heldFailures >= 3 then
            CFG.held_show = false
            destroy_held_visual()
            log("showing the other player's held item switched off after repeated errors")
        end
    end
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
    heldDirty = true      -- a new puppet needs the held item attached again
    puppetBornAt = os.clock()
    log("puppet spawned")
end

local function remove_puppet()
    destroy_held_visual()
    if puppet and puppet:IsValid() then pcall(function() puppet:K2_DestroyActor() end) end
    puppet, target = nil, nil
end

-- Animation: the puppet is teleported every tick, so the game never sees it "move" and keeps it in idle.
-- We write a Velocity into its movement component, which is what the walk/run animation reads.
-- Preferred source: the real velocity measured on the other player's game (sent with each position).
-- Fallback (other player on an older version): measure how fast the puppet itself moved this tick.
local anim = { lastT = nil, vx = 0, vy = 0, dbg = 0 }

local function set_puppet_velocity(oldX, oldY, newX, newY, teleported)
    if not CFG.sync_animation then return end
    local now = os.clock()
    local dt = anim.lastT and (now - anim.lastT) or nil
    anim.lastT = now

    local vx, vy
    if target and target.vx and (now - (target.t or 0)) < 0.5 then
        vx, vy = target.vx, target.vy
    else
        if not dt or dt < 0.005 then return end
        if dt > 0.25 then dt = 0.25 end
        vx, vy = (newX - oldX) / dt, (newY - oldY) / dt
    end
    if teleported then vx, vy = 0, 0 end
    anim.vx = anim.vx * 0.5 + vx * 0.5          -- smooth: positions only arrive every ~100 ms
    anim.vy = anim.vy * 0.5 + vy * 0.5
    local speed = math.sqrt(anim.vx * anim.vx + anim.vy * anim.vy)
    if speed < 15 then anim.vx, anim.vy, speed = 0, 0, 0 end   -- standing still -> idle

    pcall(function() puppet.CharacterMovement.Velocity = { X = anim.vx, Y = anim.vy, Z = 0 } end)

    if CFG.debug_anim then
        anim.dbg = anim.dbg + 1
        if anim.dbg % 30 == 0 then   -- about once a second
            local gv = "?"
            pcall(function() local v = puppet:GetVelocity(); gv = string.format("%.0f", math.sqrt(v.X * v.X + v.Y * v.Y)) end)
            log("anim: speed=%.0f  puppet:GetVelocity()=%s  (%s)", speed, gv, (target and target.vx) and "sender velocity" or "measured")
        end
    end
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
        local teleport = (dx * dx + dy * dy + dz * dz > 1500 * 1500)
        local a = teleport and 1.0 or 0.35
        local nx, ny, nz = cur.X + dx * a, cur.Y + dy * a, cur.Z + dz * a
        puppet:K2_SetActorLocationAndRotation(
            { X = nx, Y = ny, Z = nz },
            { Pitch = 0, Yaw = target.yaw, Roll = 0 }, false, {}, true)
        set_puppet_velocity(cur.X, cur.Y, nx, ny, teleport)
    end)
    update_held_visual()
end

---------------------------------------------------------------- held item: what the LOCAL player carries
-- Sent as  H <S|K> <meshPath> <scale xyz> <attachComponent> <socket> <relative loc xyz> <relative rot pyr>
-- (S = static mesh, K = skeletal mesh) or  H -  when the hands are empty.
-- v0.7.2: while the hands are empty the only native work is two cheap property reads, four times a second.
-- The heavier lookups (find the held actor, its mesh component, the mesh path) run once per pickup, not every
-- tick, and every one of them is wrapped in a crash breadcrumb (see the top of the held-item section).
local ACTOR_REF = "ActorRef_30_1628099C45F5C07BEFA560915FF694C4"   -- local-only actor field of the decoration save-info
local heldCacheGuid, heldCacheActor = nil, nil
local lastHeldKey, lastHeldAt = "", 0
local SMC, SKC = nil, nil
local lastIdent, lastDetectAt = nil, 0
local heldDesc = nil             -- what we last worked out the player is holding (nil = empty hands)
local heldNeedsDescribe = false
local heldTries = 0
local EMPTY_IDENT = "-|-"

local function find_class(path)
    local ok, c = pcall(StaticFindObject, path)
    if ok and isvalid(c) then return c end
    return nil
end

-- Cheap fingerprint of "what is in the hands right now": equipped item name + held decoration guid.
local function held_identity(pawn)
    local eq, g = "-", "-"
    pcall(function()
        local a = pawn.EquippedItem
        if isvalid(a) then eq = a:GetFName():ToString() end
    end)
    pcall(function() g = guidStr(pawn.CurrentHeldDecoration) end)
    if g == ZERO_GUID then g = "-" end
    return eq .. "|" .. g
end

local function find_held_actor(pawn)
    local a = nil
    pcall(function() a = pawn.EquippedItem end)            -- tools / items (scissors, string lights ...)
    if isvalid(a) then return a end

    local g = nil
    pcall(function() g = guidStr(pawn.CurrentHeldDecoration) end)
    if not g or g == ZERO_GUID then heldCacheGuid, heldCacheActor = nil, nil; return nil end
    if g == heldCacheGuid and isvalid(heldCacheActor) then return heldCacheActor end

    local mgr = getMgr()
    if not mgr then return nil end
    local actor = nil
    pcall(function()
        mgr.MasterDecorationList:ForEach(function(k, v)
            if actor then return end
            pcall(function()
                if guidStr(k:get()) == g then actor = v:get()[ACTOR_REF] end
            end)
        end)
    end)
    if isvalid(actor) then heldCacheGuid, heldCacheActor = g, actor; return actor end
    return nil
end

-- Returns "S"/"K" and the mesh if the component is a static/skeletal mesh component that has a mesh.
local function mesh_from(c)
    if not isvalid(c) then return nil, nil end
    local cn = class_name(c) or ""
    if cn:find("StaticMeshComponent", 1, true) then
        local m = nil
        pcall(function() m = c.StaticMesh end)
        if isvalid(m) then return "S", m end
    elseif cn:find("SkeletalMeshComponent", 1, true) then
        local m = nil
        pcall(function() m = c:GetSkeletalMeshAsset() end)
        if not isvalid(m) then pcall(function() m = c.SkeletalMeshAsset end) end
        if not isvalid(m) then pcall(function() m = c.SkeletalMesh end) end
        if isvalid(m) then return "K", m end
    end
    return nil, nil
end

local function describe_held(pawn)
    local actor = step("send:find_actor", function() return find_held_actor(pawn) end)
    if not isvalid(actor) then return nil end

    local kind, comp, mesh = nil, nil, nil

    -- 1) the root component is the cheapest and safest place to look
    local root = step("send:root", function() return actor:K2_GetRootComponent() end)
    if isvalid(root) then
        kind, mesh = step("send:root_mesh", function() return mesh_from(root) end)
        if kind then comp = root end
    end
    -- 2) otherwise ask the actor for a mesh component by class (only with a class we know is valid)
    if not kind then
        SMC = SMC or find_class("/Script/Engine.StaticMeshComponent")
        if SMC then
            comp = step("send:smc", function() return actor:GetComponentByClass(SMC) end)
            if isvalid(comp) then kind, mesh = step("send:smc_mesh", function() return mesh_from(comp) end) end
        end
    end
    if not kind then
        SKC = SKC or find_class("/Script/Engine.SkeletalMeshComponent")
        if SKC then
            comp = step("send:skc", function() return actor:GetComponentByClass(SKC) end)
            if isvalid(comp) then kind, mesh = step("send:skc_mesh", function() return mesh_from(comp) end) end
        end
    end
    if not kind or not isvalid(mesh) then return nil end

    local path = step("send:path", function() return objPath(mesh) end)
    if not path or path == "-" or path:find("/Transient", 1, true) then return nil end   -- runtime-made meshes can't be found by the peer

    local d = { kind = kind, mesh = path, sx = 1, sy = 1, sz = 1,
                attach = "ObjectRight", socket = "None", lx = 0, ly = 0, lz = 0, rp = 0, ry = 0, rr = 0 }
    -- The attach-parent / socket / relative-transform lookups stay removed (the v0.7.1 crash report pointed at them),
    -- so the other side always uses the puppet's ObjectRight.
    local sx, sy, sz = step("send:scale", function()
        local sc = comp:K2_GetComponentScale()
        return sc.X, sc.Y, sc.Z
    end)
    if sx then d.sx, d.sy, d.sz = sx, sy, sz end
    return d
end

local function send_held(pawn)
    if not (CFG.sync_held_item and CFG.held_send) then return end
    local now = os.clock()
    if now - connectedAt < 4 then return end                 -- let the connection and the snapshot settle first

    -- 1) at most 4x a second: has what is in the hands changed?
    if now - lastDetectAt >= 0.25 then
        lastDetectAt = now
        local ident = step("send:identity", function() return held_identity(pawn) end) or EMPTY_IDENT
        if ident ~= lastIdent then
            lastIdent = ident
            heldTries = 0
            if ident == EMPTY_IDENT then
                heldDesc, heldNeedsDescribe = nil, false
            else
                heldNeedsDescribe = true
            end
        end
        -- 2) something new in the hands: work out what it is. The decoration may not be registered the very
        --    moment it is picked up, so retry a few times before giving up.
        if heldNeedsDescribe then
            local d = describe_held(pawn)
            if d then
                heldDesc, heldNeedsDescribe = d, false
            else
                heldTries = heldTries + 1
                if heldTries >= 8 then heldDesc, heldNeedsDescribe = nil, false end
            end
        end
    end

    local d = heldDesc
    local key, line
    if d then
        key = table.concat({ d.kind, d.mesh, d.attach, d.socket }, "|")
        line = string.format("H\t%s\t%s\t%.3f\t%.3f\t%.3f\t%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f",
            d.kind, d.mesh, d.sx, d.sy, d.sz, d.attach, d.socket, d.lx, d.ly, d.lz, d.rp, d.ry, d.rr)
    else
        key, line = "-", "H\t-"
    end
    if heldNeedsDescribe then return end                      -- still working it out: don't flash "empty" at the peer
    if key ~= lastHeldKey or now - lastHeldAt > 5 then      -- on change, plus a refresh every 5 s
        if key ~= lastHeldKey then vlog("-> H %s", key) end
        lastHeldKey, lastHeldAt = key, now
        send(line)
    end
end

-- F9: print what the game says you are holding, and what the puppet has to attach it to
local wantHeldDump = false
local function dump_held()
    local pawn = getPawn()
    if not pawn then return log("F9: no player pawn yet") end
    local eq = nil
    pcall(function() eq = pawn.EquippedItem end)
    log("F9: EquippedItem = %s", isvalid(eq) and objPath(eq) or "none")
    local g = "?"
    pcall(function() g = guidStr(pawn.CurrentHeldDecoration) end)
    log("F9: CurrentHeldDecoration = %s", g)
    local d = describe_held(pawn)
    if d then
        log("F9: would send kind=%s mesh=%s attach=%s socket=%s scale=%.2f,%.2f,%.2f", d.kind, d.mesh, d.attach, d.socket, d.sx, d.sy, d.sz)
    else
        log("F9: no mesh found for the held thing (hands empty, or it has no static/skeletal mesh)")
    end
    if isvalid(puppet) then
        pcall(function() log("F9: puppet ObjectRight=%s ObjectLeft=%s", tostring(isvalid(puppet.ObjectRight)), tostring(isvalid(puppet.ObjectLeft))) end)
        pcall(function()
            local names = {}
            puppet.Mesh:GetAllSocketNames():ForEach(function(_, v)
                if #names < 40 then names[#names + 1] = v:get():ToString() end
            end)
            log("F9: puppet mesh sockets: %s", table.concat(names, ", "))
        end)
    else
        log("F9: no puppet yet")
    end
end
RegisterKeyBind(Key.F9, function() wantHeldDump = true end)   -- executed on the next game-thread tick

local function send_position()
    if not connected then return end
    local pawn = getPawn()
    if not pawn then return end
    pcall(function()
        local l, r = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
        local extra = ""
        if CFG.sync_animation then
            local vx, vy, vz = 0, 0, 0
            pcall(function() local v = pawn:GetVelocity(); vx, vy, vz = v.X, v.Y, v.Z end)
            extra = string.format("\t%.0f\t%.0f\t%.0f", vx, vy, vz)    -- old versions ignore these extra fields
        end
        send(string.format("P\t%.1f\t%.1f\t%.1f\t%.1f%s", l.X, l.Y, l.Z, r.Yaw, extra))
    end)
    local ok, e = pcall(send_held, pawn)
    if not ok then log("send_held error: %s", tostring(e)) end
end

---------------------------------------------------------------- inbound
local function handle(line)
    local f = {}
    for part in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = part end
    local kind = table.remove(f, 1)
    if kind == "U" then if CFG.enable_decorations then queue_upsert(f) end
    elseif kind == "D" then if CFG.enable_decorations then apply_destroy(f[1]) end
    elseif kind == "HELLO" then connected = true; connectedAt = os.clock(); lastHeldKey = ""; lastIdent = nil; log("peer connected"); snapshot()
    elseif kind == "BYE" then connected = false; heldWanted = nil; heldKey = "-"; remove_puppet(); log("peer disconnected")
    elseif kind == "H" then if CFG.sync_held_item and CFG.held_show then set_held_wanted(f) end
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
            local x, y, z, yaw, rest = line:match("^P\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)(.*)$")
            if x then
                target = { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), t = os.clock() }
                local vx, vy, vz = (rest or ""):match("^\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)")
                if vx then target.vx, target.vy, target.vz = tonumber(vx), tonumber(vy), tonumber(vz) end
            end
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
    if wantHeldDump then wantHeldDump = false; pcall(dump_held) end
    local ok, err = pcall(function()
        if tick % 3 == 0 then read_inbox(); send_position(); flush_dirty() end
        for _ = 1, 20 do
            local line = table.remove(queue, 1)
            if not line then break end
            local ok2, err2 = pcall(handle, line)
            if not ok2 then log("handle error: %s | %s", tostring(err2), line:sub(1, 80)) end
        end
        process_pending(2)
        process_spawn_retries()
        apply_adjustments()
        apply_cable_particles()
        update_puppet()
    end)
    if not ok and tostring(err) ~= lastErr then lastErr = tostring(err); log("tick error: %s", lastErr) end
end

install_hooks()
NotifyOnNewObject(MGR, function() install_hooks() end)
RegisterKeyBind(Key.F8, function() install_hooks() end)
log("loaded v0.8 (animation + held item + adjustments sync) on machine %s. Files folder: %s", tostring(os.getenv("COMPUTERNAME") or "?"), BASE ~= "" and BASE or "(game working dir)")
