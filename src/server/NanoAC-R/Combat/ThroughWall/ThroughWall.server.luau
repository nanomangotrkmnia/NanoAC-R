--[[
	NanoAC-R | ThroughWallCheck
	Validates melee hits against line-of-sight. The game reports every resolved hit with
	ReportHit(attacker, victim); this check drains that queue and casts a ray between the two
	players. If a solid, collidable, non-character part blocks the path, the hit went through a
	wall/defense and the attacker is flagged.

	The ray starts StartOffset studs from the attacker and stops EndOffset studs before the
	victim, so it does not hit either player's own body; only the gap between them is tested.
	Runs fully in the parallel phase (SharedTable reads + Workspace:Raycast with no params).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "ThroughWall"
local HITS = SharedTableRegistry:GetSharedTable(Shared.cfg("hitsName", "NanoAC_Hits"))

local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function isBlocking(part)
	if part == nil then return false end
	if part:IsA("Terrain") then return true end
	if not part:IsA("BasePart") then return false end
	if part.CanCollide == false then return false end
	if part.Transparency >= 0.9 then return false end
	local node, guard = part, 0
	while node ~= nil and guard < 40 do
		if node:FindFirstChildOfClass("Humanoid") ~= nil then
			return false -- another character in the line, not a wall
		end
		node = node.Parent
		guard += 1
	end
	return true
end

local function validate(rec, now)
	local origin = Vector3.new(rec.ax, rec.ay, rec.az)
	local target = Vector3.new(rec.vx, rec.vy, rec.vz)
	local delta = target - origin
	local dist = delta.Magnitude
	if dist < 0.05 then return end
	local unit = delta / dist

	local startOff = Shared.cfg("throughWallStartOffset", 1.5)
	local endOff = Shared.cfg("throughWallEndOffset", 1.0)
	local castLen = dist - startOff - endOff
	if castLen <= 0.05 then return end

	local res = Workspace:Raycast(origin + unit * startOff, unit * castLen)
	if res ~= nil and isBlocking(res.Instance) then
		local uid = rec.attacker
		streak[uid] = (streak[uid] or 0) + 1
		if streak[uid] >= Shared.cfg("throughWallRequiredStreak", 1) then
			local cd = Shared.cfg("throughWallEmitCooldown", 0.3)
			if now - (lastEmit[uid] or -math.huge) >= cd then
				Shared.flag(uid, CHECK, castLen,
					string.format("blocked by %s (%.1f studs)", res.Instance.Name, castLen))
				lastEmit[uid] = now
				streak[uid] = 0
			end
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("throughWallEnabled", true) == false then return end

	local ok, err = pcall(function()
		local write = HITS["write"]
		local read = HITS["read"]
		if write <= read then return end
		local now = os.clock()
		for i = read + 1, write do
			local rec = HITS[i]
			if rec ~= nil then
				validate(rec, now)
			end
			HITS[i] = nil
		end
		HITS["read"] = write
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] ThroughWall error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] ThroughWall check disabled after repeated errors.")
		end
	end
end)
