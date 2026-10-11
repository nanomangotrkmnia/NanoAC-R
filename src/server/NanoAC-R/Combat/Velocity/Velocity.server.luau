--[[
	NanoAC-R | VelocityCheck
	Anti-knockback / velocity. The game reports the intended knockback with
	ReportKnockback(victim, velocity); the Coordinator stores that plus the victim's position at
	the moment of the hit. This check measures the victim's real speed from its sampled
	positions, starting from that stored position so the very first sample captures the impulse.
	If the peak speed never reaches Ratio of the intended knockback, the client suppressed it.

	False-positive guards:
	  * Room  -- before flagging, a short ray is cast from the victim along the knockback
	             direction; if a solid wall sits within Room studs the knockback was physically
	             blocked, so we skip (hitting a wall is not anti-knockback).
	  * vertical knockback (little horizontal component) is never wall-skipped.
	  * MinKnockback ignores small taps; RequiredStreak + EmitCooldown debounce.

	Runs fully in the parallel phase.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Velocity"
local roster = Shared.roster
local KNOCKS = SharedTableRegistry:GetSharedTable(Shared.cfg("knocksName", "NanoAC_Knockbacks"))

local pending = {}   -- [userId] = { expected, start, t0, expire, maxSpe, lastPos, lastT, room }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

-- Is there open space in the knockback direction? (characters do not count as blockers)
local function hasRoom(startPos, dir, distance)
	local h = Vector3.new(dir.X, 0, dir.Z)
	if h.Magnitude < 0.01 then
		return true -- vertical knockback: walls cannot block it
	end
	h = h.Unit
	local origin = startPos + h * 1.5
	local len = distance - 1.5
	if len <= 0 then
		return false
	end
	local res = Workspace:Raycast(origin, h * len)
	if res == nil or res.Instance == nil then
		return true
	end
	local part = res.Instance
	local node, guard, isChar = part, 0, false
	while node ~= nil and guard < 40 do
		if node:FindFirstChildOfClass("Humanoid") ~= nil then
			isChar = true
			break
		end
		node = node.Parent
		guard += 1
	end
	if isChar then
		return true
	end
	if part:IsA("BasePart") then
		return not (part.CanCollide and part.Transparency < 0.9)
	end
	if part:IsA("Terrain") then
		return false
	end
	return true
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("velocityEnabled", true) == false then return end

	local ok, err = pcall(function()
		local minKb = Shared.cfg("velocityMinKnockback", 20)
		local window = Shared.cfg("velocityWindow", 0.35)
		local roomDist = Shared.cfg("velocityRoom", 3.5)
		local ratio = Shared.cfg("velocityRatio", 0.5)

		-- ingest reported knockbacks
		local write = KNOCKS["write"]
		local read = KNOCKS["read"]
		if write > read then
			for i = read + 1, write do
				local rec = KNOCKS[i]
				if rec ~= nil then
					local v = Vector3.new(rec.vx, rec.vy, rec.vz)
					local expected = v.Magnitude
					if expected >= minKb then
						local start = Vector3.new(rec.px or 0, rec.py or 0, rec.pz or 0)
						pending[rec.victim] = {
							expected = expected,
							start = start,
							expire = rec.t + window,
							maxSpe = 0,
							lastPos = start,
							lastT = rec.t,
							room = hasRoom(start, v, roomDist),
						}
					end
				end
				KNOCKS[i] = nil
			end
			KNOCKS["read"] = write
		end

		-- sample pending victims
		for userId, state in roster do
			local pend = pending[userId]
			if pend ~= nil then
				local pos = state.pos
				local now = state.time
				if pos ~= nil and now ~= nil then
					local dt = now - pend.lastT
					if dt > 0.0005 then
						local spe = (pos - pend.lastPos).Magnitude / dt
						if spe > pend.maxSpe then
							pend.maxSpe = spe
						end
						pend.lastPos = pos
						pend.lastT = now
					end
					if now >= pend.expire then
						if pend.room and pend.maxSpe < pend.expected * ratio then
							streak[userId] = (streak[userId] or 0) + 1
							if streak[userId] >= Shared.cfg("velocityRequiredStreak", 1) then
								local cd = Shared.cfg("velocityEmitCooldown", 0.3)
								if now - (lastEmit[userId] or -math.huge) >= cd then
									Shared.flag(userId, CHECK, pend.expected - pend.maxSpe,
										string.format("expected=%.1f got=%.1f", pend.expected, pend.maxSpe))
									lastEmit[userId] = now
									streak[userId] = 0
								end
							end
						end
						pending[userId] = nil
					end
				end
			end
		end
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] Velocity error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Velocity check disabled after repeated errors.")
		end
	end
end)
