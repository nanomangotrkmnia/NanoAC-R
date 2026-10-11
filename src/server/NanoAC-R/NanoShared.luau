--[[
	NanoAC-R | NanoShared
	Shared, serialisable communication layer for every check + the Coordinator.

	This module is REQUIRED IN A SERIAL CONTEXT (never while desynchronised), so it can
	cache service handles up-front. Every function below only reads/writes SharedTables
	or pure values, which makes them safe to call from parallel phases.

	Beware: a regular Luau table can NOT be shared across Actors. Everything that crosses
	thread boundaries lives in a SharedTable from SharedTableRegistry.
]]

local SharedTableRegistry = game:GetService("SharedTableRegistry")
local Players = game:GetService("Players")

local NanoShared = {}

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

-- Push a confirmed violation onto the cross-thread queue. Safe to call in parallel.
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

-- Clamp helper used by the sustained checks.
function NanoShared.clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

return NanoShared
