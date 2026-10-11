--[[
	NanoAC-R | RemoteGuard  (serial sensor)

	Watches client->server RemoteEvent traffic and flags:
	  * global spam        -- more than remoteMaxPerSecond invocations/second per player.
	  * per-remote spam    -- more than remoteMaxPerRemotePerSecond invocations/second on a
	                          single remote.
	  * oversized payloads -- string/table payloads larger than remoteMaxPayload characters,
	                          or more than remoteMaxArgs arguments.

	RemoteFunction.OnServerInvoke is a single callback (not a signal) so it cannot be hooked
	without breaking the game; those are left alone (ExploitGuard covers their *names*). This
	script is a serial sensor: it does not desynchronise and pushes violations straight to the
	shared queue via Shared.flag.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Remote"

local hooked = {}          -- [RemoteEvent] = true
local globalTimes = {}     -- [userId] = { {t=os.clock(), remote=name}, ... }
local remoteTimes = {}     -- [userId] = { [remoteName] = { t, ... } }
local lastEmit = {}

local function push(userId, magnitude, detail)
	local now = os.clock()
	if now - (lastEmit[userId] or -math.huge) < Shared.cfg("remoteEmitCooldown", 0.5) then return end
	lastEmit[userId] = now
	Shared.flag(userId, CHECK, magnitude, detail)
end

local function argSize(v, depth)
	local t = typeof(v)
	if t == "string" then
		return #v
	elseif t == "number" then
		return 8
	elseif t == "boolean" then
		return 4
	elseif t == "table" then
		if depth > 4 then return 0 end
		local s, n = 0, 0
		for k, val in pairs(v) do
			n += 1
			if n > 250 then break end
			local ks = type(k) == "string" and #k or 8
			s += ks + argSize(val, depth + 1)
		end
		return s
	end
	return 0
end

local function onInvoke(remote, plr, ...)
	local userId = plr.UserId
	local now = os.clock()
	local maxPayload = Shared.cfg("remoteMaxPayload", 8000)
	local maxArgs = Shared.cfg("remoteMaxArgs", 12)

	local argc = select("#", ...)
	local args = table.pack(...)

	-- payload size
	local ok, size = pcall(function()
		local s = 0
		for i = 1, argc do
			s += argSize(args[i], 0)
		end
		return s
	end)
	if ok and size > maxPayload then
		push(userId, size, string.format("%s payload=%d chars", remote.Name, size))
		return
	end

	-- per-remote window
	local rt = remoteTimes[userId]
	if rt == nil then rt = {}; remoteTimes[userId] = rt end
	local list = rt[remote.Name]
	if list == nil then list = {}; rt[remote.Name] = list end
	list[#list + 1] = now
	while #list >= 1 and list[1] < now - 1.0 do table.remove(list, 1) end
	while #list > 400 do table.remove(list, 1) end
	if #list > Shared.cfg("remoteMaxPerRemotePerSecond", 30) then
		push(userId, #list, string.format("%s x%d/s", remote.Name, #list))
		return
	end

	-- global window
	local g = globalTimes[userId]
	if g == nil then g = {}; globalTimes[userId] = g end
	g[#g + 1] = now
	while #g >= 1 and g[1] < now - 1.0 do table.remove(g, 1) end
	while #g > 600 do table.remove(g, 1) end
	if #g > Shared.cfg("remoteMaxPerSecond", 60) then
		push(userId, #g, string.format("global %d/s", #g))
		return
	end

	if argc > maxArgs then
		push(userId, argc, string.format("%s args=%d", remote.Name, argc))
	end
end

local function hook(inst)
	if not inst:IsA("RemoteEvent") then return end
	if inst:IsDescendantOf(rootActor) then return end
	if hooked[inst] then return end
	hooked[inst] = true
	inst.OnServerEvent:Connect(function(plr, ...)
		if not Shared.cfg("remoteEnabled", true) then return end
		local ok, err = pcall(onInvoke, inst, plr, ...)
		if not ok then
			warn("[NanoAC-R] RemoteGuard error: " .. tostring(err))
		end
	end)
end

local function scan()
	for _, inst in ipairs(game:GetDescendants()) do
		hook(inst)
	end
end

task.spawn(function()
	scan()
	game.DescendantAdded:Connect(function(inst)
		pcall(hook, inst)
	end)

	-- periodic cleanup of idle tracking so a long session cannot grow unbounded
	while true do
		task.wait(30)
		for userId in pairs(globalTimes) do
			if Players:GetPlayerByUserId(userId) == nil then
				globalTimes[userId] = nil
				remoteTimes[userId] = nil
				lastEmit[userId] = nil
			end
		end
	end
end)
