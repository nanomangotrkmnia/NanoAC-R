--[[
	NanoAC-R | DescendCheck  (FlightC)
	Vertical CONTROLLED-FALL check. Flags a player who is falling but far slower than gravity
	should allow (parachute / glide-down / reduced-gravity).

	It measures how long the player has actually been falling (vy < -MinFallSpeed), then
	compares the real descent speed to the freefall speed that time should have produced
	(gravity * fallTime, capped at terminal). If the real fall is below ExpectedRatio of that,
	they are descending under control -> flag. A normal jump/fall matches freefall, so it never
	flags. Not the same as fast-fall (that is the opposite signature).
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "FlightC"
local roster = Shared.roster

local prev = {}      -- [userId] = { pos, time }
local fall = {}      -- [userId] = { start = number }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function reset(userId)
	prev[userId] = nil
	fall[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local p = prev[userId]
	if p == nil or p.time == nil or p.time <= 0 or (t - p.time) > 0.5 then
		prev[userId] = { pos = pos, time = t }
		fall[userId] = nil
		streak[userId] = 0
		return
	end

	local dt = t - p.time
	local oldPos = p.pos
	p.pos = pos
	p.time = t
	if dt <= 0.001 then return end

	if state.grounded == true or Shared.isExempt(state, t) then
		fall[userId] = nil
		streak[userId] = 0
		return
	end

	local vy = (pos.Y - oldPos.Y) / dt
	local minFall = Shared.cfg("flightCMinFallSpeed", 8)

	if vy < -minFall then
		local f = fall[userId]
		if f == nil then
			f = { start = t }
			fall[userId] = f
		end
		local fallTime = t - f.start
		if fallTime >= Shared.cfg("flightCMinFallTime", 0.3) then
			local gravity = Shared.cfg("gravity", 196)
			local expected = math.min(gravity * fallTime, 200)
			local actual = -vy
			if actual < expected * Shared.cfg("flightCExpectedRatio", 0.55) then
				streak[userId] = (streak[userId] or 0) + 1
				if streak[userId] > Shared.cfg("flightCRequiredStreak", 0) then
					local cd = Shared.cfg("flightCEmitCooldown", 0.5)
					if t - (lastEmit[userId] or -math.huge) >= cd then
						Shared.flag(userId, CHECK, expected - actual,
							string.format("fall=%.1f expected=%.1f over %.2fs", actual, expected, fallTime))
						lastEmit[userId] = t
					end
				end
			else
				streak[userId] = 0
			end
		else
			streak[userId] = 0
		end
	else
		fall[userId] = nil
		streak[userId] = 0
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("flightCEnabled", true) == false then return end

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
			warn("[NanoAC-R] FlightC error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] FlightC check disabled after repeated errors.")
		end
	end
end)
