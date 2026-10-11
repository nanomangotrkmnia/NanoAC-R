--[[
	NanoAC-R | Phase(A)  (through-wall raycast)
	Detects a player whose movement path passes FULLY through a solid, collidable wall.
	(The collision-off variant of the Phase family lives in Movement/PhaseB as Phase(B).)

	The ray runs from the player's LAST VALID (safe, supported) position to their current
	position, exactly as the design calls for. Because that origin freezes while a player is
	airborne or phasing, the path spans the whole suspicious movement and can cross a wall even
	at ordinary walking speed.

	This is the one check that needs workspace raycasts, so it uses the hybrid pattern:
	  * SERIAL phase   : read the shared state, grab each character (building the raycast
	                     exclusion list is NOT allowed in parallel), then task.desynchronize().
	  * PARALLEL phase : cast the forward ray (origin -> current) and the backwards ray
	                     (current -> origin). When both hit the SAME obstacle, the wall
	                     thickness crossed along the path is (len - forwardDist - backDist).
	                     A positive thickness above the tolerance means the path crossed the
	                     wall completely.

	Leniency: thin/steppable parts, non-collidable parts, invisible parts, other characters and
	water are ignored. Minor corner clipping is ignored (the crossed thickness must be a
	meaningful fraction of the whole path). Over-long paths and high speeds are deferred to
	Speed/Teleport rather than flagged here.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Phase(A)"
local roster = Shared.roster

local streak = {}    -- [userId] = number
local lastEmit = {}  -- [userId] = number

local disabled = false
local errors = 0
local lastErrLog = 0

local function isSolidObstacle(hit, maxTransparency, minThickness)
	local part = hit.Instance
	if part == nil then return false end

	if part:IsA("Terrain") then
		local m = hit.Material
		return m ~= Enum.Material.Water and m ~= Enum.Material.Air
	end

	if not part:IsA("BasePart") then return false end
	if part.CanCollide == false then return false end            -- non-collidable -> ignore
	if part.Transparency >= maxTransparency then return false end -- invisible -> ignore

	local node = part
	local guard = 0
	while node ~= nil and guard < 40 do
		if node:FindFirstChildOfClass("Humanoid") ~= nil then
			return false                                          -- other characters -> ignore
		end
		node = node.Parent
		guard += 1
	end

	local size = part.Size
	local minDim = math.min(size.X, size.Y, size.Z)
	if minDim <= minThickness then return false end               -- thin/steppable -> ignore

	return true
end

local function evaluate(job)
	local params = job.params
	local from = job.from
	local to = job.to
	local delta = to - from
	local len = delta.Magnitude
	if len < 1e-3 then return end

	local maxTrans = Shared.cfg("phaseAMaxTransparency", 0.9)
	local minThick = Shared.cfg("phaseAMinPartThickness", 0.6)

	local fwd = Workspace:Raycast(from, delta, params)
	if fwd == nil then return end
	if not isSolidObstacle(fwd, maxTrans, minThick) then return end
	if fwd.Distance < 0.15 then return end

	local back = Workspace:Raycast(to, -delta, params)
	if back == nil then return end
	if back.Instance ~= fwd.Instance then return end
	if not isSolidObstacle(back, maxTrans, minThick) then return end

	local thickness = len - fwd.Distance - back.Distance
	if thickness < math.max(minThick, len * 0.25) then return end

	local userId = job.userId
	streak[userId] = (streak[userId] or 0) + 1
	if streak[userId] >= Shared.cfg("phaseARequiredStreak", 2) then
		local cd = Shared.cfg("phaseAEmitCooldown", 0.6)
		if job.now - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, thickness,
				string.format("through %s (%.2f studs)", fwd.Instance.Name, thickness))
			lastEmit[userId] = job.now
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:Connect(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("phaseAEnabled", true) == false then return end

	local jobs = {}

	-- ---------------------------- SERIAL -------------------------------------------------
	local ok, err = pcall(function()
		local minMove = Shared.cfg("phaseAMinMove", 2.5)
		local maxSeg = Shared.cfg("phaseAMaxSegment", 60)
		local factor = Shared.cfg("phaseASpeedFactor", 1.6)
		for _, plr in ipairs(Players:GetPlayers()) do
			local userId = plr.UserId
			local state = roster[userId]
			if state ~= nil then
				local pos = state.pos
				local t = state.time
				local origin = state.lastValidPos
				local originT = state.lastValidTime
				if pos ~= nil and t ~= nil and t > 0
					and origin ~= nil and originT ~= nil and originT > 0
					and state.dead ~= true and state.alive ~= false
					and not Shared.isExempt(state, t) then
					local dt = t - originT
					local len = (pos - origin).Magnitude
					local walk = state.walkSpeed or 16
					if dt > 0 and len >= minMove and len <= maxSeg and (len / dt) <= walk * factor then
						local char = plr.Character
						if char ~= nil then
							local params = RaycastParams.new()
							params.FilterType = Enum.RaycastFilterType.Exclude
							params.FilterDescendantsInstances = { char }
							jobs[#jobs + 1] = {
								userId = userId,
								from = origin,
								to = pos,
								params = params,
								dt = dt,
								walkSpeed = walk,
								now = t,
							}
						end
					end
				end
			end
		end
	end)

	if not ok then
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] Phase(A) gather error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		return
	end

	if #jobs == 0 then return end

	-- ---------------------------- PARALLEL -----------------------------------------------
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
			warn("[NanoAC-R] Phase(A) error: " .. tostring(err2))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Phase(A) check disabled after repeated errors.")
		end
	end
end)
