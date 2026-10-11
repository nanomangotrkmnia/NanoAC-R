--[[
	NanoAC-R | FlingGuard
	Detects the fling exploit: an attacker spins its own HumanoidRootPart at an extreme
	angular velocity and/or linear speed so that a collision transfers enormous momentum
	to nearby players.

	The Coordinator publishes the root's AssemblyAngularVelocity / AssemblyLinearVelocity
	each frame; this check flags values far beyond anything normal locomotion produces,
	requiring a streak so a momentarily-flung victim does not false-flag (an attacker
	sustains the spin; a victim's spin is one or two frames).
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Fling"
local roster = Shared.roster

local streak = {}
local lastEmit = {}

local function reset(userId)
	streak[userId] = nil
end

local function process(state, userId, t)
	if Shared.isGrace(state, t) or state.phys == true then
		streak[userId] = 0
		return
	end

	local ang = state.angSpeed or 0
	local speed = state.vel and state.vel.Magnitude or 0
	local maxAng = Shared.cfg("flingMaxAngular", 60)
	local maxSpeed = Shared.cfg("flingMaxSpeed", 750)

	local bad, detail
	if ang > maxAng then
		bad, detail = true, string.format("angular=%.1f rad/s", ang)
	elseif speed > maxSpeed then
		bad, detail = true, string.format("speed=%.1f", speed)
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("flingRequiredStreak", 2) then
		local cd = Shared.cfg("flingEmitCooldown", 0.4)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, ang, detail or "fling")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "flingEnabled",
	process = process,
	reset = reset,
})
