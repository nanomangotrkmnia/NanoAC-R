--[[
	NanoAC-R | Flight(E)  (PlatformStand fly/hover)
	Covers the PlatformStand flight vectors the FlightA-D checks deliberately exempt via the
	shared isExempt() (which skips PlatformStand):

	  * PlatformStand fly / hover  -- PlatformStand is true while airborne and the body
	                                  hovers (|vy| small) for MinAirTime, or ascends faster
	                                  than MinAscent.

	Swim-in-air is a separate mode (Flight/FlightF, check Flight(F)), so it is intentionally
	NOT handled here.

	Ragdoll/physics states are still skipped (PlatformStand is legitimate there). Whitelist
	legit launchers / hover mechanics with ExemptTeleport or the whitelist attribute.
]]

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Flight(E)"
local roster = Shared.roster

local hoverTime = {}   -- [userId] = seconds hovering under PlatformStand
local streak = {}
local lastEmit = {}

local function reset(userId)
	hoverTime[userId] = nil
	streak[userId] = nil
end

local function process(state, userId, t)
	if Shared.isGrace(state, t) or state.phys == true then
		hoverTime[userId] = 0
		streak[userId] = 0
		return
	end

	local dt = state.dt or 0
	local bad, detail

	if state.platformStand == true and state.airborne == true then
		local vy = state.vy or 0
		if math.abs(vy) < Shared.cfg("flightEMaxDescent", 8) then
			hoverTime[userId] = (hoverTime[userId] or 0) + dt
			if hoverTime[userId] >= Shared.cfg("flightEMinAirTime", 0.6) then
				bad, detail = true, string.format("platform hover=%.2fs vy=%.1f", hoverTime[userId], vy)
			end
		elseif vy > Shared.cfg("flightEMinAscent", 8) then
			bad, detail = true, string.format("platform ascend vy=%.1f", vy)
		else
			hoverTime[userId] = 0
		end
	else
		hoverTime[userId] = 0
	end

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("flightERequiredStreak", 2) then
		local cd = Shared.cfg("flightEEmitCooldown", 0.4)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, 0, detail or "fly")
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

Shared.runCheck({
	check = CHECK,
	enabledKey = "flightEEnabled",
	process = process,
	reset = reset,
})
