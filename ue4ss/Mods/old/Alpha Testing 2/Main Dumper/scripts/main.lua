local MGR  = "/Game/Blueprints/DecorationManager/BP_DecorationManager.BP_DecorationManager_C"
local DEC  = "/Game/Blueprints/Decorations/BP_Decoration.BP_Decoration_C"
local CHAR = "/Game/Blueprints/BP_HolidayCharacter.BP_HolidayCharacter_C"

local targets = {
  MGR .. ":SpawnAndRegisterDecorationV2",
  MGR .. ":CreateDecorationFromSaveInfo",
  MGR .. ":UpdateDecorationInfo",
  MGR .. ":DestroyDecoration",
  MGR .. ":SwapDecoration",
  MGR .. ":ChangeDecorationType",
  MGR .. ":UpdateDecorationActorRef",
  MGR .. ":AddDecUserAdjustment",
  MGR .. ":SaveDecorations",
  DEC .. ":GetSaveInfo",
  DEC .. ":ApplyDecorationSaveInfo",
  DEC .. ":SetUpFromDecorationInfo",
}

local function tname(p) return p:GetClass():GetFName():ToString() end

local function walk(st, indent, depth, out)
  st:ForEachProperty(function(p)
    local t = tname(p)
    local line = indent .. p:GetFName():ToString() .. " : " .. t
    if t == "StructProperty" then
      local ok, inner = pcall(function() return p:GetStruct() end)
      if ok and inner then
        out[#out + 1] = line .. " <" .. inner:GetFName():ToString() .. ">"
        if depth < 3 then walk(inner, indent .. "    ", depth + 1, out) end
        return
      end
    end
    out[#out + 1] = line
  end)
end

RegisterKeyBind(Key.F7, function()
  local out = {}
  for _, path in ipairs(targets) do
    out[#out + 1] = "=== " .. path
    local ok, obj = pcall(StaticFindObject, path)
    if ok and obj and obj:IsValid() then
      local ok2, err = pcall(walk, obj, "  ", 0, out)
      if not ok2 then out[#out + 1] = "  ERROR: " .. tostring(err) end
    else
      out[#out + 1] = "  NOT FOUND"
    end
  end

  out[#out + 1] = "=== BP_HolidayCharacter held-decoration structs"
  local cls = StaticFindObject(CHAR)
  if cls and cls:IsValid() then
    cls:ForEachProperty(function(p)
      local n = p:GetFName():ToString()
      if n == "CurrentHeldDecoration" or n == "CurrentDecorationASS" or n == "SelectedDecoration" then
        local ok, inner = pcall(function() return p:GetStruct() end)
        out[#out + 1] = "  " .. n .. " : " .. tname(p) .. (ok and inner and (" <" .. inner:GetFName():ToString() .. ">") or "")
        if ok and inner then pcall(walk, inner, "      ", 1, out) end
      end
    end)
  end

  local f = io.open("StructDump.txt", "w")
  if f then f:write(table.concat(out, "\n")); f:close() end
  print("[StructDump] wrote " .. #out .. " lines\n")
end)