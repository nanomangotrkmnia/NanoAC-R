--[[
	NanoAC-R | PhysicsGuard
	Flags physics objects planted on a character: injected body movers / forces / constraints
	(BodyVelocity, BodyAngularVelocity, BodyForce, LinearVelocity, VectorForce, AlignOrientation,
	LineForce, RopeConstraint, ...) that are not part of a legitimately-joined character.

	The Coordinator performs the (throttled) descendant scan and publishes the unfiltered
	count; anything marked with the NanoAC_Legit attribute or named in physicsIgnoreNames is
	excluded there, so this check only has to compare the count.

	Games that legitimately attach movers to characters should tag the instance with
	NanoAC_Legit = true (server side) or add its name to Checks.Physics.IgnoreNames.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Physics"
local roster = Shared.roster

local streak = {}
local lastEmit = {}

local function reset(userId)
	streak[userId] = nil
end

local function process(state, userId, t)
	if Shared.isGrace(state, t) then
		streak[userId] = 0
		return
	end

	local bad = (state.physCount or 0) > 0
	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("physicsRequiredStreak", 1) then
		local cd = Shared.cfg("physicsEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, state.physCount or 0,
				string.format("physics objects=%d", state.physCount or 0))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "physicsEnabled",
	process = process,
	reset = reset,
})
