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

--[[
	Config snapshot.

	A SharedTable read is not free: it crosses the shared boundary and takes the table's
	lock. The checks read the same handful of config keys every frame for every player, so
	reading them straight out of the SharedTable each time is pure overhead. Instead we
	copy the whole (flat) config SharedTable into a plain Luau table once and answer
	cfg()/cfgList() from that snapshot. The snapshot is rebuilt only when the Coordinator
	bumps CONFIG.revision, which it does whenever it republishes config.

	Each check Actor gets its own snapshot (a ModuleScript is per-Actor state), which is
	exactly what we want: no cross-Actor sharing, nothing to synchronise.
]]
local cfgCache = {}
local cfgBuilt = false
local cfgRevision = nil

-- Rebuild the local config snapshot if the Coordinator has published a new revision.
-- Cheap no-op in the steady state.
function NanoShared.syncConfig()
	local rev = NanoShared.config.revision
	if cfgBuilt and rev == cfgRevision then
		return
	end
	local snapshot = {}
	for k, v in NanoShared.config do
		snapshot[k] = v
	end
	cfgCache = snapshot
	cfgRevision = rev
	cfgBuilt = true
end

-- Read a published config value from the local snapshot, with a fallback when the
-- Coordinator hasn't set it yet. A miss refreshes once so a check that loaded before
-- the Coordinator still picks the value up. Because the snapshot is only invalidated
-- on a revision change, we also poll the revision every CFG_REVISION_POLL calls so a
-- mid-session republish propagates without a shared read on every single access.
local CFG_REVISION_POLL = 64
local cfgCalls = 0

function NanoShared.cfg(key, default)
	local v = cfgCache[key]
	if v == nil then
		NanoShared.syncConfig()
		v = cfgCache[key]
		if v == nil then
			return default
		end
		return v
	end
	cfgCalls += 1
	if cfgCalls >= CFG_REVISION_POLL then
		cfgCalls = 0
		if NanoShared.config.revision ~= cfgRevision then
			NanoShared.syncConfig()
			v = cfgCache[key]
			if v == nil then
				return default
			end
		end
	end
	return v
end

-- Split a delimited string config value into a list (used for name/pattern lists).
-- The parse result is memoised per key and only recomputed when the raw string changes,
-- so repeated calls in hot paths stop rebuilding the same table every time.
local cfgListCache = {}   -- [key] = { raw = string, parsed = {string} }

function NanoShared.cfgList(key, default)
	local v = NanoShared.cfg(key, nil)
	if type(v) == "string" then
		local raw = v :: string
		local cached = cfgListCache[key]
		if cached ~= nil and cached.raw == raw then
			return cached.parsed
		end
		local out = {}
		for item in string.gmatch(raw, "[^,]+") do
			local trimmed = string.match(item, "^%s*(.-)%s*$")
			if trimmed ~= "" then
				out[#out + 1] = trimmed
			end
		end
		cfgListCache[key] = { raw = raw, parsed = out }
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

--[[
	Exemption checks.

	Every movement/death flag here is only ever published by the Coordinator's sample(),
	so the Coordinator can precompute them as one aggregate (state.exemptMove / .exemptGrace)
	and a check pays a single shared read instead of up to nine. The whitelist flag and the
	grace windows, however, are also written asynchronously (ExemptTeleport, seat changes,
	setbacks, the whitelist API), so those are still read live to keep the exact
	same-frame behaviour. `now` is the caller's sample time.

	The individual checks remain the fallback for any state table that predates the
	aggregate fields.
]]
function NanoShared.isExempt(state, now)
	if state == nil then return true end

	local aggregate = state.exemptMove
	if aggregate == true then return true end

	-- Live values that can change between samples.
	if state.whitelisted == true then return true end
	local grace = state.graceUntil
	if grace ~= nil and now < grace then return true end
	local exempt = state.exemptUntil
	if exempt ~= nil and now < exempt then return true end

	-- With an aggregate present, the movement flags are authoritative (sample-only).
	if aggregate ~= nil then
		return false
	end

	-- No aggregate: fall back to the full original evaluation.
	if state.dead == true then return true end
	if state.seated == true then return true end
	if state.swim == true then return true end
	if state.climb == true then return true end
	if state.platform == true then return true end
	if state.phys == true then return true end
	return false
end

-- Stricter variant that ignores the *movement* exemptions (swim/climb/seat/platform)
-- but still honours death, whitelist and grace windows. Used by the property/state
-- guards (HumanoidGuard, StateGuard, NoclipGuard, PhysicsGuard, ...) which must still
-- run while a player is seated/swimming. Aggregated as state.exemptGrace (see above).
function NanoShared.isGrace(state, now)
	if state == nil then return true end

	local aggregate = state.exemptGrace
	if aggregate == true then return true end

	-- Live values that can change between samples.
	if state.whitelisted == true then return true end
	local grace = state.graceUntil
	if grace ~= nil and now < grace then return true end
	local exempt = state.exemptUntil
	if exempt ~= nil and now < exempt then return true end

	-- The aggregate is authoritative for the sample-only death flags.
	if aggregate ~= nil then
		return false
	end
	if state.dead == true then return true end
	if state.alive == false then return true end
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

	--[[
		Roster snapshot.

		Iterating the roster SharedTable costs a locked shared read per element every tick.
		Membership changes rarely, so instead we cache a plain Luau array of the (userId,
		state) pairs and iterate that with a numeric for-loop. The array is rebuilt only
		when the Coordinator bumps CONFIG.rosterGen on join/leave (one shared read per
		tick to notice the change). Field reads from each state are unchanged, but the
		iteration machinery no longer touches the SharedTable every check every frame.
	]]
	local snapshot = {}       -- [i] = state
	local snapshotIds = {}    -- [i] = userId
	local snapshotCount = 0
	local rosterGen = nil

	local function rebuildRoster()
		local n = 0
		for userId, state in NanoShared.roster do
			n += 1
			snapshot[n] = state
			snapshotIds[n] = userId
		end
		for i = n + 1, snapshotCount do
			snapshot[i] = nil
			snapshotIds[i] = nil
		end
		snapshotCount = n
	end

	-- Defined once (not per tick) so the frame path allocates no closures.
	local function runRoster()
		for i = 1, snapshotCount do
			local state = snapshot[i]
			local t = state.time
			if t ~= nil and t > 0 then
				if state.dead == true or state.alive == false then
					if reset ~= nil then reset(snapshotIds[i]) end
				else
					process(state, snapshotIds[i], t)
				end
			end
		end
	end

	local function tick()
		if disabled then return end
		if NanoShared.cfg("paused", false) then return end
		if enabledKey ~= nil and NanoShared.cfg(enabledKey, true) == false then return end

		local gen = NanoShared.config.rosterGen
		if gen ~= rosterGen then
			rosterGen = gen
			rebuildRoster()
		end

		local ok, err = pcall(runRoster)

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
