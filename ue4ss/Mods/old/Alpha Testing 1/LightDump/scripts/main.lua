local dumpCount = 0
local lastPress = 0

local function dump()
    local now = os.clock()
    if now - lastPress < 1.0 then return end
    lastPress = now

    ExecuteInGameThread(function()
        local counts = {}
        local actors = FindAllOf("Actor")
        if not actors then
            print("[LightDump] no actors found\n")
            return
        end
        for _, a in ipairs(actors) do
            if a:IsValid() then
                local name = a:GetClass():GetFullName()
                counts[name] = (counts[name] or 0) + 1
            end
        end
        local names = {}
        for name in pairs(counts) do names[#names + 1] = name end
        table.sort(names)

        dumpCount = dumpCount + 1
        local fileName = "D:/SteamLibrary/steamapps/common/Light Up The Town/LightUpTheTown/Binaries/Win64/ue4ss/LightDump_" .. dumpCount .. ".txt"
        local f = io.open(fileName, "w")
        for _, name in ipairs(names) do
            f:write(counts[name], "  ", name, "\n")
        end
        f:close()
        print("[LightDump] wrote " .. fileName .. "\n")
    end)
end

RegisterKeyBind(Key.F6, dump)
print("[LightDump] loaded, press F6 in-game\n")