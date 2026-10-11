--[[
	NanoAC-R | HumanoidGuard
	Detects tampering with the Humanoid locomotion properties that every other movement
	check treats as its trusted baseline:
	    WalkSpeed, JumpPower, JumpHeight, HipHeight, MaxSlopeAngle.

	The Coordinator captures a per-character spawn baseline; this check flags a value that
	has drifted from that baseline beyond its tolerance for several consecutive samples.
	Legitimate games that deliberately change these values should either set them at spawn
	(before the baseline is captured) or mark the player with the whitelist attribute /
	NanoAC_Whitelisted, which exempts them everywhere.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Humanoid"
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

	local bad
	local detail

	local walk, walkBase = state.walkSpeed or 16, state.walkBase or 16
	if math.abs(walk - walkBase) > Shared.cfg("humanoidWalkTolerance", 0.75) then
		bad, detail = true, string.format("walk=%.1f base=%.1f", walk, walkBase)
	end

	if not bad then
		local jump, jumpBase = state.jumpPower or 50, state.jumpBase or 50
		if math.abs(jump - jumpBase) > Shared.cfg("humanoidJumpTolerance", 2) then
			bad, detail = true, string.format("jumpPower=%.1f base=%.1f", jump, jumpBase)
		end
	end

	if not bad then
		local hip, hipBase = state.hipHeight or 2, state.hipBase or 2
		if math.abs(hip - hipBase) > Shared.cfg("humanoidHipTolerance", 0.35) then
			bad, detail = true, string.format("hip=%.2f base=%.2f", hip, hipBase)
		end
	end

	if not bad then
		local jh, jhBase = state.jumpHeight, state.jumpHeightBase
		if jh ~= nil and jhBase ~= nil
			and math.abs(jh - jhBase) > Shared.cfg("humanoidJumpHeightTolerance", 0.5) then
			bad, detail = true, string.format("jumpHeight=%.2f base=%.2f", jh, jhBase)
		end
	end

	if not bad then
		local slopeBase = state.slopeBase
		local liveSlope = state.maxSlopeAngle
		if liveSlope ~= nil and slopeBase ~= nil
			and math.abs(liveSlope - slopeBase) > Shared.cfg("humanoidSlopeTolerance", 1.0) then
			bad, detail = true, string.format("slope=%.1f base=%.1f", liveSlope, slopeBase)
		end
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("humanoidRequiredStreak", 2) then
		local cd = Shared.cfg("humanoidEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "humanoid tamper")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "humanoidEnabled",
	process = process,
	reset = reset,
})
