--[[
	NanoAC-R | FlightD  (air jump / sustained mid-air rise)
	A jump can only START from the ground, and once airborne gravity only pulls you DOWN. After
	the short legit jump window (~0.27s rise) a normal player is always descending. So: if the
	player is airborne well past takeoff AND still gaining altitude, that is an air jump / boost.

	This is robust (it keys off the SIGN of vertical speed, not noisy per-frame acceleration) and
	catches the "jump, fall a bit, jump again" bypass that resets FlightA/B/C while still gaining
	height. Reads the Coordinator-published vy / airborne / wasAirborne. Grounded/supported states
	and grace windows are exempt; whitelist launchers with the ExemptTeleport API.
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "FlightD"
local roster = Shared.roster

local airStart = {}   -- [userId] = time airborne began
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function process(state, t, userId)
	if state.airborne ~= true then
		airStart[userId] = nil
		streak[userId] = 0
		return
	end

	-- first airborne sample == takeoff, start the clock
	if state.wasAirborne ~= true then
		airStart[userId] = t
		streak[userId] = 0
		return
	end

	if Shared.isExempt(state, t) then
		streak[userId] = 0
		return
	end

	-- allow the normal jump rise window
	if (t - (airStart[userId] or t)) < Shared.cfg("flightDAirDelay", 0.55) then
		streak[userId] = 0
		return
	end

	-- still rising this long after leaving the ground == air jump
	local vy = state.vy or 0
	if vy > Shared.cfg("flightDMinRise", 8) then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("flightDRequiredStreak", 1) then
		local cd = Shared.cfg("flightDEmitCooldown", 0.3)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, vy,
				string.format("airjump air=%.2fs vy=%.1f", t - (airStart[userId] or t), vy))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("flightDEnabled", true) == false then return end

	local ok, err = pcall(function()
		for userId, state in roster do
			local t = state.time
			if t ~= nil and t > 0 then
				if state.dead == true or state.alive == false then
					airStart[userId] = nil
					streak[userId] = 0
				else
					process(state, t, userId)
				end
			end
		end
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] FlightD error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] FlightD check disabled after repeated errors.")
		end
	end
end)
