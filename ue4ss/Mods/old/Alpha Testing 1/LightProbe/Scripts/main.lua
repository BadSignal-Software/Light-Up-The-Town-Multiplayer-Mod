local lastPress = 0
local outFile = "D:/SteamLibrary/steamapps/common/Light Up The Town/LightUpTheTown/Binaries/Win64/ue4ss/LightProbe.txt"

local classes = {
    "/Game/Blueprints/DecorationManager/BP_DecorationManager.BP_DecorationManager_C",
    "/Game/Blueprints/Cables/BP_Decoration_Cable.BP_Decoration_Cable_C",
    "/Game/Meshes/Decorations/Items/Current/SkeletalMesh/Cable/BP_Item_Cable_StringLight.BP_Item_Cable_StringLight_C",
    "/Game/Blueprints/Decorations/Props/BP_Decoration_Prop.BP_Decoration_Prop_C",
    "/Game/Blueprints/Decorations/Props/CandyCane/Item_CandyCane.Item_CandyCane_C",
    "/Game/Blueprints/Decorations/Props/Snowman/Item_Snowman.Item_Snowman_C",
    "/Game/Blueprints/BP_HolidayCharacter.BP_HolidayCharacter_C",
}

local function probe()
    local now = os.clock()
    if now - lastPress < 1.0 then return end
    lastPress = now

    ExecuteInGameThread(function()
        local f = io.open(outFile, "w")
        for _, path in ipairs(classes) do
            f:write("=== ", path, "\n")
            local c = StaticFindObject(path)
            if c and c:IsValid() then
                while c and c:IsValid() do
                    local full = c:GetFullName()
                    f:write("-- ", full, "\n")
                    if full:find("/Script/") then break end
                    pcall(function()
                        c:ForEachProperty(function(p)
                            f:write("  P ", p:GetFName():ToString(), " : ", p:GetClass():GetFName():ToString(), "\n")
                        end)
                    end)
                    pcall(function()
                        c:ForEachFunction(function(fn)
                            f:write("  F ", fn:GetFName():ToString(), "\n")
                        end)
                    end)
                    c = c:GetSuperStruct()
                end
            else
                f:write("not found\n")
            end
        end
        f:close()
        print("[LightProbe] wrote " .. outFile .. "\n")
    end)
end

RegisterKeyBind(Key.F7, probe)
print("[LightProbe] loaded, press F7 in-game\n")