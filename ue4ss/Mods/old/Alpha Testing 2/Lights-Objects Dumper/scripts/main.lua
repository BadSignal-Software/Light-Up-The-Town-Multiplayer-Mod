local MGR = "/Game/Blueprints/DecorationManager/BP_DecorationManager.BP_DecorationManager_C"
local fns = {
  "SpawnAndRegisterDecorationV2", "CreateDecorationFromSaveInfo",
  "UpdateDecorationInfo", "DestroyDecoration", "SwapDecoration",
  "ChangeDecorationType", "UpdateDecorationActorRef", "AddDecUserAdjustment",
}

local hooked = false
RegisterKeyBind(Key.F6, function()
  if hooked then return end
  hooked = true
  for _, name in ipairs(fns) do
    local ok, err = pcall(function()
      RegisterHook(MGR .. ":" .. name, function(self, ...)
        local parts = {}
        for i, a in ipairs({...}) do
          local ok2, v = pcall(function() return a:get() end)
          parts[#parts + 1] = i .. "=" .. (ok2 and tostring(v) or "?")
        end
        print(string.format("[NetProbe] %s(%s)\n", name, table.concat(parts, ", ")))
      end)
    end)
    if not ok then print("[NetProbe] hook failed: " .. name .. " - " .. tostring(err) .. "\n") end
  end
  print("[NetProbe] hooks installed\n")
end)