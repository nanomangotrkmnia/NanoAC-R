--[[
	NanoAC-R | TeleportCheck
	Parallel-phase sudden-position-jump detection. Compares single-sample displacement against
	the maximum travel possible over the elapsed time (scaled by WalkSpeed / JumpPower for
	upward motion / terminal velocity for downward motion, plus a flat ping allowance).

	Distinguishes from legitimate events because respawns, character loads, seat entry/exit and
	whitelisted game teleports all set the shared exemptUntil window (see Coordinator's
	ExemptTeleport API and lifecycle handlers), and high-speed falling uses the terminal-velocity
	allowance. A "hard" overrun (many times the allowance) flags immediately; smaller overruns
	must persist for RequiredStreak samples, which keeps lag batching from false-flagging.
]]

local RunService = game:GetService("RunService")

local rootActor = script:FindFirstAncestor("NanoAC-R")
local Shared = require(rootActor:WaitForChild("NanoShared"))

local CHECK = "Teleport"
local roster = Shared.roster

local prev = {}      -- [userId] = { pos = Vector3, time = number }
local streak = {}    -- [userId] = number
local lastEmit = {}  -- [userId] = number

local disabled = false
local errors = 0
local lastErrLog = 0

local function reset(userId)
	prev[userId] = nil
	streak[userId] = 0
end

local function process(state, userId, t)
	local pos = state.pos
	if pos == nil then return end

	local p = prev[userId]
	if p == nil or p.time == nil or p.time <= 0 then
		prev[userId] = { pos = pos, time = t }
		return
	end

	local dt = t - p.time
	local oldPos = p.pos
	p.pos = pos
	p.time = t

	if dt <= 0.001 then return end
	if dt > 0.5 then
		-- missed frames: allowances scale with dt, but rebaseline to stay safe
		return
	end
	if Shared.isExempt(state, t) then
		streak[userId] = 0
		return
	end

	local delta = pos - oldPos
	local horiz = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local up = math.max(0, delta.Y)
	local down = math.max(0, -delta.Y)

	local walk = state.walkSpeed or 16
	local jump = state.jumpPower or 50
	local ping = state.ping or 0
	local pingSlack = Shared.cfg("teleportPingAllowance", 14) * ping

	local hAllow = walk * Shared.cfg("teleportHorizMultiplier", 2.0) * dt + pingSlack
	local upAllow = jump * Shared.cfg("teleportUpMultiplier", 3.0) * dt + pingSlack
	local downAllow = Shared.cfg("teleportTerminalVelocity", 300) * Shared.cfg("teleportDownMultiplier", 1.5) * dt + pingSlack
	local minDist = Shared.cfg("teleportMinDistance", 12)

	local overH = horiz > hAllow and horiz > minDist
	local overU = up > upAllow and up > minDist
	local overD = down > downAllow and down > minDist
	local bad = overH or overU or overD

	local hard = (horiz > hAllow * 4 and horiz > minDist)
		or (up > upAllow * 4 and up > minDist)
		or (down > downAllow * 4 and down > minDist)

	if bad then
		streak[userId] = (streak[userId] or 0) + 1
	else
		streak[userId] = 0
	end

	local need = Shared.cfg("teleportRequiredStreak", 2)
	if hard or streak[userId] >= need then
		local cd = Shared.cfg("teleportEmitCooldown", 0.6)
		if t - (lastEmit[userId] or -math.huge) >= cd then
			Shared.flag(userId, CHECK, math.max(horiz - hAllow, math.abs(delta.Y)),
				string.format("jump h=%.1f v=%.1f over %.3fs", horiz, delta.Y, dt))
			lastEmit[userId] = t
			streak[userId] = 0
		end
	end
end

RunService.PreSimulation:ConnectParallel(function()
	if disabled then return end
	if Shared.cfg("paused", false) then return end
	if Shared.cfg("teleportEnabled", true) == false then return end

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
			warn("[NanoAC-R] Teleport error: " .. tostring(err))
			lastErrLog = os.clock()
		end
		if errors >= 10 then
			disabled = true
			warn("[NanoAC-R] Teleport check disabled after repeated errors.")
		end
	end
end)
