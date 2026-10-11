--[[
	NanoAC-R | StepCheck
	Flags stepping/climbing vertically while grounded by more than the engine's legitimate step
	height in a single frame. Walking up stairs/ramps or slopes produces small per-frame gains;
	a Step hack yanks you straight up a tall ledge without jumping.

	Only evaluated while grounded (a jump leaves the ground, so jumps never match) and only the
	grounded vertical delta matters. Grace/teleport/setback windows are exempt via isExempt.
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Step"
local roster = Shared.roster

local prev = {}
local streak = {}
local lastEmit = {}
local disabled, errors, lastErrLog = false, 0, 0

local function reset(userId)
	prev[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local p = prev[userId]
	if p == nil or p.time == nil or p.time <= 0 or (t - p.time) > 0.5 then
		prev[userId] = { pos = pos, time = t }
		streak[userId] = 0
		return
	end

	local dt = t - p.time
	local oldPos = p.pos
	p.pos = pos
	p.time = t
	if dt <= 0.001 then return end

	if state.grounded ~= true or Shared.isExempt(state, t) then
		streak[userId] = 0
		return
	end

	local dy = pos.Y - oldPos.Y
	local maxStep = Shared.cfg("stepMaxStep", 2.75)
	if dy > maxStep then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	if streak[userId] >= Shared.cfg("stepRequiredStreak", 2) then
		local cd = Shared.cfg("stepEmitCooldown", 0.4)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, dy,
				string.format("step=%.2f (max %.2f)", dy, maxStep))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("stepEnabled", true) == false then return end

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
			warn("[NanoAC-R] Step error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Step check disabled after repeated errors.")
		end
	end
end)
