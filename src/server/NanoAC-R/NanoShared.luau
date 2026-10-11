--[[
	NanoAC-R | NanoShared
	Shared, serialisable communication layer for every check + the Coordinator.

	This module is REQUIRED IN A SERIAL CONTEXT (never while desynchronised), so it can
	cache service handles up-front. Every function below only reads/writes SharedTables
	or pure values, which makes them safe to call from parallel phases.

	Beware: a regular Luau table can NOT be shared across Actors. Everything that crosses
	thread boundaries lives in a SharedTable from SharedTableRegistry.
]]

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")
local Players = game:GetService("Players")

local NanoShared = {}
NanoShared.RunService = RunService

-- Registry names. Keep in sync with the Coordinator.
NanoShared.NAMES = {
	ROSTER = "NanoAC_Roster",
	QUEUE = "NanoAC_Queue",
	CONFIG = "NanoAC_Config",
}

-- Resolve the shared handles once, at require time (serial).
NanoShared.roster = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.ROSTER)
NanoShared.queue = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.QUEUE)
NanoShared.config = SharedTableRegistry:GetSharedTable(NanoShared.NAMES.CONFIG)
NanoShared.Players = Players

-- The queue is a growable array addressed by two numeric cursors. SharedTable.increment
-- requires the key to already exist and be numeric, so seed them if they are absent.
if NanoShared.queue["write"] == nil then NanoShared.queue["write"] = 0 end
if NanoShared.queue["read"] == nil then NanoShared.queue["read"] = 0 end

-- Read a published config value, with a fallback when the Coordinator hasn't set it yet.
function NanoShared.cfg(key, default)
	local v = NanoShared.config[key]
	if v == nil then
		return default
	end
	return v
end

-- Split a delimited string config value into a list (used for name/pattern lists).
function NanoShared.cfgList(key, default)
	local v = NanoShared.config[key]
	if type(v) == "string" then
		local out = {}
		for item in string.gmatch(v, "[^,]+") do
			local trimmed = string.match(item, "^%s*(.-)%s*$")
			if trimmed ~= "" then
				out[#out + 1] = trimmed
			end
		end
		return out
	end
	if type(v) == "table" then
		return v
	end
	return default or {}
end

-- ---- Generic cross-thread queues ------------------------------------------------
-- A named queue is a SharedTable shaped { write:number, read:number, [i] = SharedTable }.
-- Returns (queue, indexWrittenTo). Safe to call from parallel contexts.
function NanoShared.pushQueue(queue, payload)
	local old = SharedTable.increment(queue, "write", 1)
	local index = old + 1
	queue[index] = SharedTable.new(payload)
	return index
end

-- Push a confirmed violation onto the shared queue. Safe to call in parallel.
-- Returns the slot index it wrote to.
function NanoShared.pushViolation(userId, checkName, magnitude, detail)
	local old = SharedTable.increment(NanoShared.queue, "write", 1)
	local index = old + 1
	NanoShared.queue[index] = SharedTable.new({
		userId = userId,
		check = checkName,
		magnitude = magnitude or 0,
		detail = detail or "",
	})
	return index
end

-- Canonical flag API used by every check. pushViolation is kept as an alias.
NanoShared.flag = NanoShared.pushViolation

-- True when a check should ignore this player this frame. Exempts everything the brief
-- calls out: dead/respawning, seated, swimming, climbing, ragdoll/physics, platform
-- standing, spawn grace and teleport/teleport-whitelist grace.
function NanoShared.isExempt(state, now)
	if state == nil then return true end
	if state.whitelisted == true then return true end
	if state.dead == true then return true end
	if state.seated == true then return true end
	if state.swim == true then return true end
	if state.climb == true then return true end
	if state.platform == true then return true end
	if state.phys == true then return true end
	local grace = state.graceUntil
	if grace ~= nil and now < grace then return true end
	local exempt = state.exemptUntil
	if exempt ~= nil and now < exempt then return true end
	return false
end

-- Stricter variant that ignores the *movement* exemptions (swim/climb/seat/platform)
-- but still honours death, whitelist and grace windows. Used by the property/state
-- guards (HumanoidGuard, StateGuard, NoclipGuard, PhysicsGuard, ...) which must still
-- run while a player is seated/swimming.
function NanoShared.isGrace(state, now)
	if state == nil then return true end
	if state.whitelisted == true then return true end
	if state.dead == true then return true end
	if state.alive == false then return true end
	local grace = state.graceUntil
	if grace ~= nil and now < grace then return true end
	local exempt = state.exemptUntil
	if exempt ~= nil and now < exempt then return true end
	return false
end

-- Clamp helper used by the sustained checks.
function NanoShared.clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

--[[
	runCheck -- boilerplate-free parallel check runner.

	New checks pass closures instead of copy-pasting the roster loop + pcall + disable
	guard. The callbacks run inside the parallel phase; they must only touch SharedTables
	and pure values (never the DataModel).

	  NanoShared.runCheck({
	     check       = "HumanoidGuard",
	     enabledKey  = "humanoidEnabled",
	     process     = function(state, userId, t) ... end,
	     reset       = function(userId) ... end,   -- optional, on death/despawn
	     serial      = true,                        -- optional, run in serial phase
	  })
]]
function NanoShared.runCheck(opts)
	local check = opts.check or "Check"
	local enabledKey = opts.enabledKey
	local process = opts.process
	local reset = opts.reset
	local disabled = false
	local errors = 0
	local lastErrLog = 0

	local function tick()
		if disabled then return end
		if NanoShared.cfg("paused", false) then return end
		if enabledKey ~= nil and NanoShared.cfg(enabledKey, true) == false then return end

		local ok, err = pcall(function()
			for userId, state in NanoShared.roster do
				local t = state.time
				if t ~= nil and t > 0 then
					if state.dead == true or state.alive == false then
						if reset ~= nil then reset(userId) end
					else
						process(state, userId, t)
					end
				end
			end
		end)

		if not ok then
			errors += 1
			if os.clock() - lastErrLog > 5 then
				warn(string.format("[NanoAC-R] %s error: %s", check, tostring(err)))
				lastErrLog = os.clock()
			end
			if errors >= 10 then
				disabled = true
				warn(string.format("[NanoAC-R] %s check disabled after repeated errors.", check))
			end
		end
	end

	if opts.serial then
		RunService.PreSimulation:Connect(tick)
	else
		RunService.PreSimulation:ConnectParallel(tick)
	end
end

return NanoShared
