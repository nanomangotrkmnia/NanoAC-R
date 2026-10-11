--[[
	NanoAC-R | IntegrityGuard
	Flags tampering with the Humanoid state machine itself:
	  * Dead state disabled      -- the client removed the ability to die.
	  * Freefall state disabled  -- gravity / freefall removed.
	  * Flying state enabled     -- the client enabled flight.
	  * extra Humanoids          -- a second Humanoid planted in the character (used to
	                                hijack locomotion / respawn logic).

	These are cheap, high-signal booleans sampled by the Coordinator each frame.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Integrity"
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

	local bad, detail
	if state.deadDisabled == true and state.deadDisabledBase == false then
		bad, detail = true, "Dead state disabled"
	elseif state.freefallDisabled == true and state.freefallDisabledBase == false then
		bad, detail = true, "Freefall state disabled"
	elseif state.flyingEnabled == true and state.flyingEnabledBase == false then
		bad, detail = true, "Flying state enabled"
	elseif (state.humanoidCount or 1) > 1 then
		bad, detail = true, string.format("humanoids=%d", state.humanoidCount)
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("integrityRequiredStreak", 2) then
		local cd = Shared.cfg("integrityEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "integrity")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "integrityEnabled",
	process = process,
	reset = reset,
})
