--[[
	NanoAC-R | ToolGuard  (serial sensor, auto-hooks character tools)

	Flags tool abuse without the game having to integrate anything:
	  * equip spam    -- more than toolMaxEquipsPerSecond Tools added to the character.
	  * activate spam -- more than toolMaxActivatesPerSecond Tool.Activated events.

	It automatically watches every player's character (and every Tool that enters it), counts
	the events in a rolling window and pushes a violation. Tools are hooked as they are added
	and unhooked as they leave; nothing needs to be registered by the game.
]]

local Players = game:GetService("Players")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Tool"

local equips = {}     -- [userId] = { t, ... }
local activates = {}  -- [userId] = { t, ... }
local lastEmit = {}
local hookedTools = {} -- [Tool] = { activated = connection }

local function trim(list, now, window)
	while #list >= 1 and list[1] < now - window do
		table.remove(list, 1)
	end
	while #list > 400 do
		table.remove(list, 1)
	end
end

local function push(userId, magnitude, detail)
	local now = os.clock()
	if now - (lastEmit[userId] or -math.huge) < Shared.cfg("toolEmitCooldown", 0.5) then return end
	lastEmit[userId] = now
	Shared.flag(userId, CHECK, magnitude, detail)
end

local function noteEquip(userId)
	if not Shared.cfg("toolEnabled", true) then return end
	local now = os.clock()
	local window = Shared.cfg("toolWindow", 1.0)
	local list = equips[userId]
	if list == nil then list = {}; equips[userId] = list end
	list[#list + 1] = now
	trim(list, now, window)
	if #list > Shared.cfg("toolMaxEquipsPerSecond", 6) then
		push(userId, #list, string.format("equips=%d/%0.1fs", #list, window))
	end
end

local function noteActivate(userId, toolName)
	if not Shared.cfg("toolEnabled", true) then return end
	local now = os.clock()
	local window = Shared.cfg("toolWindow", 1.0)
	local list = activates[userId]
	if list == nil then list = {}; activates[userId] = list end
	list[#list + 1] = now
	trim(list, now, window)
	if #list > Shared.cfg("toolMaxActivatesPerSecond", 14) then
		push(userId, #list, string.format("activates=%d/%0.1fs %s", #list, window, tostring(toolName)))
	end
end

local function hookTool(plr, tool)
	if not tool:IsA("Tool") then return end
	-- equip event == the Tool just entered the character
	noteEquip(plr.UserId)
	if hookedTools[tool] then return end
	local conn = tool.Activated:Connect(function()
		local ok, err = pcall(noteActivate, plr.UserId, tool.Name)
		if not ok then
			warn("[NanoAC-R] ToolGuard error: " .. tostring(err))
		end
	end)
	hookedTools[tool] = { activated = conn }
	tool.AncestryChanged:Connect(function()
		if not tool:IsDescendantOf(game) then
			local h = hookedTools[tool]
			if h and h.activated then h.activated:Disconnect() end
			hookedTools[tool] = nil
		end
	end)
end

local function watchCharacter(plr, char)
	for _, child in ipairs(char:GetChildren()) do
		hookTool(plr, child)
	end
	char.ChildAdded:Connect(function(child)
		pcall(hookTool, plr, child)
	end)
end

local function watchPlayer(plr)
	if plr.Character then
		watchCharacter(plr, plr.Character)
	end
	plr.CharacterAdded:Connect(function(char)
		watchCharacter(plr, char)
	end)
end

Players.PlayerAdded:Connect(watchPlayer)
for _, plr in ipairs(Players:GetPlayers()) do
	watchPlayer(plr)
end
Players.PlayerRemoving:Connect(function(plr)
	equips[plr.UserId] = nil
	activates[plr.UserId] = nil
	lastEmit[plr.UserId] = nil
end)
