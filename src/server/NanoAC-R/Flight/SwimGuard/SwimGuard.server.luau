--[[
	NanoAC-R | SwimGuard  (swim-in-air)  --  new mode

	A dedicated mode for the "swim in air" exploit: the client forces the Humanoid into the
	Swimming state while the character is not in water (FloorMaterial is not Water). Left
	unchecked, swimming lets a player glide/move through the air like flight.

	This is intentionally a SEPARATE check from FlyGuard (which owns PlatformStand fly /
	hover / illegal ascent). The shared isExempt() skips the genuine Swimming state, so this
	guard uses isGrace() (death + grace windows only) and requires the swimming state to
	persist swimMinTime seconds, so entering/leaving a real pool never false-flags.

	The Coordinator publishes state.swimInAir = (Humanoid state == Swimming) and
	(FloorMaterial ~= Water) every frame.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Swim"
local roster = Shared.roster

local swimTime = {}  -- [userId] = seconds spent swimming in air
local streak = {}
local lastEmit = {}

local function reset(userId)
	swimTime[userId] = nil
	streak[userId] = nil
end

local function process(state, userId, t)
	if Shared.isGrace(state, t) then
		swimTime[userId] = 0
		streak[userId] = 0
		return
	end

	local bad, detail
	if state.swimInAir == true then
		local dt = state.dt or 0
		swimTime[userId] = (swimTime[userId] or 0) + dt
		if swimTime[userId] >= Shared.cfg("swimMinTime", 0.4) then
			bad, detail = true, string.format("swim-in-air=%.2fs", swimTime[userId])
		end
	else
		swimTime[userId] = 0
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("swimRequiredStreak", 2) then
		local cd = Shared.cfg("swimEmitCooldown", 0.4)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "swim-in-air")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "swimEnabled",
	process = process,
	reset = reset,
})
