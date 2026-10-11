--[[
	NanoAC-R | GlideCheck  (FlightB)
	Vertical HOVER check. Flags a player who stays airborne while barely falling (|vy| small)
	for longer than a jump could. A normal jump's climb + apex only keeps vy above -MaxDescent
	for ~0.3s, which is below MinAirTime, so ordinary jumps never flag.

	Airborne + |downward speed| < MaxDescent for MinAirTime seconds => glide / float.
	Seated, swimming, climbing, platform, physics, dead and all grace windows are exempt.
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "FlightB"
local roster = Shared.roster

local prev = {}      -- [userId] = { pos, time }
local hover = {}     -- [userId] = { start = number }
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function reset(userId)
	prev[userId] = nil
	hover[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local p = prev[userId]
	if p == nil or p.time == nil or p.time <= 0 or (t - p.time) > 0.5 then
		prev[userId] = { pos = pos, time = t }
		hover[userId] = nil
		streak[userId] = 0
		return
	end

	local dt = t - p.time
	local oldPos = p.pos
	p.pos = pos
	p.time = t
	if dt <= 0.001 then return end

	if state.grounded == true or Shared.isExempt(state, t) then
		hover[userId] = nil
		streak[userId] = 0
		return
	end

	local vy = (pos.Y - oldPos.Y) / dt
	local maxDescent = Shared.cfg("flightBMaxDescent", 8)

	if vy > -maxDescent then
		local h = hover[userId]
		if h == nil then
			h = { start = t }
			hover[userId] = h
		end
		local dur = t - h.start
		if dur >= Shared.cfg("flightBMinAirTime", 0.6) then
			streak[userId] = (streak[userId] or 0) + 1
			if streak[userId] > Shared.cfg("flightBRequiredStreak", 0) then
				local cd = Shared.cfg("flightBEmitCooldown", 0.4)
				if t - (lastEmit[userId] or -math.huge) >= cd then
					Shared.flag(userId, CHECK, dur,
						string.format("hover=%.2fs vy=%.1f", dur, vy))
					lastEmit[userId] = t
				end
			end
		else
			streak[userId] = 0
		end
	else
		hover[userId] = nil
		streak[userId] = 0
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("flightBEnabled", true) == false then return end

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
			warn("[NanoAC-R] FlightB error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] FlightB check disabled after repeated errors.")
		end
	end
end)
