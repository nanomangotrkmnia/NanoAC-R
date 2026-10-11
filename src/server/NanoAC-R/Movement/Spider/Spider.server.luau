--[[
	NanoAC-R | SpiderCheck
	Flags climbing vertical walls without a ladder/truss. A Spider hack sustains upward speed
	while pressed against a solid wall.

	Hybrid threading like Phase(A): the SERIAL phase gathers each airborne player, builds the
	raycast exclusion list (not allowed in parallel), then task.desynchronize() casts four
	horizontal probes for a nearby solid wall. Climbing an actual ladder sets the Humanoid
	Climbing state (state.climb), which the Coordinator publishes and which exempts the player,
	so ladders/trusses/vines never false-flag.

	A normal jump next to a wall only keeps upward speed for ~0.25s, below MinSustain, so it is
	safe; a spider sustains the climb and flags.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Spider"
local roster = Shared.roster

local prevY = {}     -- [userId] = { y, t }
local climb = {}     -- [userId] = { start = number }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function wallAhead(origin, dist, params)
	local dirs = {
		Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
		Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
	}
	for _, d in ipairs(dirs) do
		local res = Workspace:Raycast(origin, d * dist, params)
		if res ~= nil then
			local part = res.Instance
			if part ~= nil then
				if part:IsA("Terrain") then
					if res.Material ~= Enum.Material.Water and res.Material ~= Enum.Material.Air then
						return true
					end
				elseif part:IsA("BasePart") and part.CanCollide then
					local node, guard, isChar = part, 0, false
					while node ~= nil and guard < 40 do
						if node:FindFirstChildOfClass("Humanoid") ~= nil then
							isChar = true
							break
						end
						node = node.Parent
						guard += 1
					end
					if not isChar then
						return true
					end
				end
			end
		end
	end
	return false
end

local function evaluate(job)
	local t = job.now
	if wallAhead(job.origin, Shared.cfg("spiderWallDistance", 2.2), job.params) then
		local c = climb[job.userId]
		if c == nil then
			c = { start = t }
			climb[job.userId] = c
		end
		local dur = t - c.start
		if dur >= Shared.cfg("spiderMinSustain", 0.35) then
			streak[job.userId] = (streak[job.userId] or 0) + 1
			if streak[job.userId] > Shared.cfg("spiderRequiredStreak", 0) then
				local cd = Shared.cfg("spiderEmitCooldown", 0.4)
				if t - (lastEmit[job.userId] or -math.huge) >= cd then
					Shared.flag(job.userId, CHECK, dur,
						string.format("wallclimb=%.2fs vy=%.1f", dur, job.vy))
					lastEmit[job.userId] = t
				end
			end
		else
			streak[job.userId] = 0
		end
	else
		climb[job.userId] = nil
		streak[job.userId] = 0
	end
end

RunService.PreSimulation:Connect(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("spiderEnabled", true) == false then return end

	local jobs = {}
	local ok, err = pcall(function()
		local minSpeed = Shared.cfg("spiderMinClimbSpeed", 4)
		for _, plr in ipairs(Players:GetPlayers()) do
			local userId = plr.UserId
			local state = roster[userId]
			if state ~= nil then
				local pos = state.pos
				local t = state.time
				if pos ~= nil and t ~= nil and t > 0 then
					local old = prevY[userId]
					prevY[userId] = { y = pos.Y, t = t }
					if state.grounded ~= true
						and state.dead ~= true and state.alive ~= false
						and state.climb ~= true
						and not Shared.isExempt(state, t)
						and old ~= nil and (t - old.t) > 0.001 then
						local vy = (pos.Y - old.y) / (t - old.t)
						if vy > minSpeed then
							local char = plr.Character
							if char ~= nil then
								local params = RaycastParams.new()
								params.FilterType = Enum.RaycastFilterType.Exclude
								params.FilterDescendantsInstances = { char }
								jobs[#jobs + 1] = { userId = userId, origin = pos, params = params, vy = vy, now = t }
							end
						else
							climb[userId] = nil
						end
					else
						climb[userId] = nil
					end
				end
			end
		end
	end)

	if not ok then
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] Spider gather error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		return
	end
	if #jobs == 0 then return end

	task.desynchronize()
	local ok2, err2 = pcall(function()
		for _, job in ipairs(jobs) do
			evaluate(job)
		end
	end)
	task.synchronize()

	if not ok2 then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] Spider error: " .. tostring(err2))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Spider check disabled after repeated errors.")
		end
	end
end)
