--[[
	NanoAC-R | StateGuard
	Flags humanoid states a legitimate server-authoritative game should never leave a
	player in:
	  * Flying              -- the Flying state is enabled/active (client-controlled flight)
	  * StrafingNoPhysics   -- movement with physics disabled
	  * fake sit            -- Humanoid.Sit is true but the character is not attached to any
	                           SeatPart, i.e. a spoofed Seated state used to dodge movement
	                           checks / fake animations.

	The fake-sit case must persist SitGrace seconds so a genuine seat transition (which
	briefly clears SeatPart) is never flagged.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "State"
local roster = Shared.roster

local sitTime = {}   -- [userId] = seconds spent in a seatless sit
local streak = {}
local lastEmit = {}

local function reset(userId)
	sitTime[userId] = nil
	streak[userId] = nil
end

local function process(state, userId, t)
	if Shared.isGrace(state, t) then
		sitTime[userId] = 0
		streak[userId] = 0
		return
	end

	local bad, detail

	if state.flying == true then
		bad, detail = true, "Flying state"
	elseif state.strafingNoPhysics == true then
		bad, detail = true, "StrafingNoPhysics state"
	end

	if not bad and state.sitNoSeat == true then
		local dt = state.dt or 0
		sitTime[userId] = (sitTime[userId] or 0) + dt
		if sitTime[userId] >= Shared.cfg("stateSitGrace", 1.0) then
			bad, detail = true, "seatless Sit"
		end
	else
		sitTime[userId] = 0
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("stateRequiredStreak", 2) then
		local cd = Shared.cfg("stateEmitCooldown", 0.5)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "bad state")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "stateEnabled",
	process = process,
	reset = reset,
})
