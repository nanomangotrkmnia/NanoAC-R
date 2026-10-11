--[[
	NanoAC-R | AscendCheck  (FlightA)
	Vertical UPWARD check. Catches gaining altitude faster/higher than a legitimate jump can,
	which is exactly the short "high jump" boost that slips under a hover-only check.

	Two independent triggers (both while airborne, non-exempt):
	  1. Windowed average upward speed exceeds jumpPower * MaxMultiplier.
	  2. Altitude climbed inside GainWindow exceeds maxJumpHeight * GainMultiplier + Leniency.

	Whitelist legitimate launchers (jump pads, cannons) with the Coordinator's
	ExemptTeleport API, which sets exemptUntil for every check.
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "FlightA"
local roster = Shared.roster

local prev = {}      -- [userId] = { pos, time }
local gain = {}      -- [userId] = { data = { {t, y} } }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function reset(userId)
	prev[userId] = nil
	gain[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local p = prev[userId]
	if p == nil or p.time == nil or p.time <= 0 or (t - p.time) > 0.5 then
		prev[userId] = { pos = pos, time = t }
		gain[userId] = { data = { { t = t, y = pos.Y } } }
		streak[userId] = 0
		return
	end

	local dt = t - p.time
	local oldPos = p.pos
	p.pos = pos
	p.time = t
	if dt <= 0.001 then return end

	-- Only an AIRBORNE player can be legitimately ascending. Running into a wall keeps the
	-- player grounded (the engine auto-steps), so skipping grounded play removes the false flag.
	if state.grounded == true or Shared.isExempt(state, t) then
		gain[userId] = { data = { { t = t, y = pos.Y } } }
		streak[userId] = 0
		return
	end

	local gw = gain[userId]
	if gw == nil then gw = { data = {} }; gain[userId] = gw end
	local data = gw.data
	data[#data + 1] = { t = t, y = pos.Y }
	local window = Shared.cfg("flightAGainWindow", 0.35)
	while #data >= 2 and data[1].t < t - window do
		table.remove(data, 1)
	end
	local windowGain = pos.Y - data[1].y
	local windowTime = t - data[1].t
	local avgUp = (windowTime > 0.001) and (windowGain / windowTime) or 0

	local jump = state.jumpPower or 50
	if jump <= 0 then jump = 50 end
	local gravity = Shared.cfg("gravity", 196)
	local maxSpeed = jump * Shared.cfg("flightAMaxMultiplier", 1.35)
	local maxJumpHeight = (jump * jump) / (2 * gravity)
	local maxGain = maxJumpHeight * Shared.cfg("flightAGainMultiplier", 1.3) + Shared.cfg("flightALeniency", 2)

	-- Window AVERAGE (not a single-frame dy/dt) plus a filled window so one stepped/teleport
	-- sample can never spike this into a flag.
	local filled = windowTime >= window * 0.6
	local bad = filled and ((avgUp > maxSpeed) or (windowGain > maxGain))
	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("flightARequiredStreak", 2) then
		local cd = Shared.cfg("flightAEmitCooldown", 0.4)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, windowGain,
				string.format("avgUp=%.1f gain=%.1f window=%.2fs jump=%.0f", avgUp, windowGain, windowTime, jump))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("flightAEnabled", true) == false then return end

	local ok, err = pcall(function()
		for userId, state in roster do
			local t = state.time
			if t ~= nil and t > 0 then
				if state.dead == true or state.alive == false then
					reset(userId)
				else
					process(state, userId, t)
				end
			end
		end
	end)

	if not ok then
		errors += 1
		if os.clock() - lastErrLog > 5 then
			warn("[NanoAC-R] FlightA error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] FlightA check disabled after repeated errors.")
		end
	end
end)
