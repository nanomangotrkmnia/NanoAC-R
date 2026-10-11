# NanoAC-R

A complete, server-side movement anticheat for Roblox, inspired by **GrimAC** but rewritten
from scratch for Roblox's engine. It is written in Luau and built around **Parallel Luau**:
every check runs off the main thread inside its own `Actor`, and the only script that ever
touches the DataModel is the `Coordinator`.

> A missed cheat is preferable to punishing a legit player. Every threshold is scaled by ping
> and elapsed time, every confirmation is required to persist across multiple samples, and if a
> check is ever uncertain it stays silent.

---

## 1. Actor hierarchy

Everything lives under `ServerScriptService`:

```
ServerScriptService
└─ NanoAC-R                            (Actor)
   ├─ NanoShared                       (ModuleScript)  serial communication layer
   ├─ ExemptTeleport                   (BindableFunction) teleport whitelist API
   ├─ ReportHit                        (BindableFunction) combat API (attacker, victim)
   ├─ ReportKnockback                  (BindableFunction) combat API (victim, velocity)
   ├─ Core        (Folder)
   │  └─ Coordinator                   (Actor) → Coordinator (Script)  <- serial
   ├─ Movement    (Folder)
   │  ├─ Phase                         (Actor) → Phase     (Script)  <- NoClip
   │  ├─ Speed                         (Actor) → Speed     (Script)
   │  ├─ Timer                         (Actor) → Timer     (Script)  <- game speed
   │  ├─ Teleport                      (Actor) → Teleport  (Script)
   │  ├─ Step                          (Actor) → Step      (Script)  <- instant step-up
   │  └─ Spider                        (Actor) → Spider    (Script)  <- wall climb
   ├─ Flight      (Folder)
   │  ├─ FlightA                       (Actor) → FlightA   (Script)  <- up (high-jump)
   │  ├─ FlightB                       (Actor) → FlightB   (Script)  <- hover / float
   │  └─ FlightC                       (Actor) → FlightC   (Script)  <- controlled fall
   └─ Combat      (Folder)
      ├─ ThroughWall                   (Actor) → ThroughWall (Script) <- hit through walls
      └─ Velocity                      (Actor) → Velocity  (Script)  <- anti-knockback
```

Each check is one `Actor` containing one `Script` inside a category Folder (folders do not
affect parallelism — only the nearest ancestor `Actor` matters).

`ReplicatedStorage` gets a `NanoAC_AlertEvent` (RemoteEvent), and
`StarterPlayer.StarterPlayerScripts` gets a `NanoAC_AlertClient` (LocalScript) that renders the
alerts in chat. Both are created/installed automatically; the coordinator also creates the
remote at runtime if it is missing.

**Adding a new check = adding one new child `Actor` containing one `Script`.** Nothing else
changes; the new script just reads the shared state and pushes to the shared queue.

---

## 2. Threading model

| Concern | Owner |
| --- | --- |
| DataModel writes (setbacks, alerts, lifecycle) | `Coordinator` — **serial only** |
| Per-player shared state (position, flags, limits) | `Coordinator` writes, checks read |
| Per-frame movement maths (prediction, raycasts, rolling windows) | check scripts — **parallel** |
| Confirmed violations | checks push into a `SharedTable` queue |
| Violation levels, decay, alerts, setbacks | `Coordinator` drains the queue each frame |

* Regular Lua tables **cannot** be shared between parallel contexts. Cross-thread state lives in
  `SharedTable`s obtained from `SharedTableRegistry`.
* `NanoShared` (the module) is required in a **serial** context so it can cache service handles;
  its functions only touch `SharedTable`s / pure values, so they are safe to call in parallel.
* The pure-data checks use `RunService.PreSimulation:ConnectParallel`. The `Phase` check uses
  `PreSimulation:Connect` and calls `task.desynchronize()` after a short serial prep step,
  because building a `RaycastParams` exclusion list is not allowed in parallel.
* Each check wraps its whole tick in `pcall`. On an error it logs (throttled) and, after 10
  errors, disables **only itself** — every other check keeps running.

### Shared tables (created via `SharedTableRegistry`)

| Name | Shape |
| --- | --- |
| `NanoAC_Roster` | `userId -> playerState` (a nested SharedTable) |
| `NanoAC_Queue` | `{ write:number, read:number, [i] = {userId, check, magnitude, detail} }` |
| `NanoAC_Config` | flat `string -> number/boolean` mirror of the Settings table |

`playerState` keys: `userId, name, pos (Vector3), time, dt, ping, walkSpeed, jumpPower,
hipHeight, grounded, stateName, swim, climb, seated, platform, phys, dead, freefall, jumping,
alive, graceUntil, exemptUntil, lastValidPos (Vector3), lastValidYaw, setbackCount`.
Only SharedTable-compatible types are stored (numbers, booleans, strings, `Vector3`, nested
SharedTables); CFrames are stored as a position + a yaw scalar.

Because `SharedTable.increment` requires a pre-existing numeric key, `NanoShared` seeds
`queue.write` / `queue.read` to `0` at load, and the coordinator drains with them every frame.

---

## 3. The checks

### Phase (NoClip) — `PhaseCheck.Phase`
Casts a ray from the last position to the current position and a second ray backwards from the
current position. When both hit the **same** obstacle, the thickness crossed along the segment
is `len - forwardDistance - backDistance`. A positive thickness that is a meaningful fraction
of the whole segment means the segment passed fully through the wall. Ignores thin/steppable
parts, non-collidable parts, invisible parts, other characters and water; ignores corner
clipping (needs `len * 0.25`), and defers to Speed/Teleport when the player moved fast enough to
tunnel legitimately.

### Speed — `SpeedCheck.Speed`
Horizontal displacement / `dt` versus `WalkSpeed * MaxMultiplier + ping allowance`, confirmed
by a rolling average over a window and a consecutive-sample streak. Exempts every unsupported
movement state and all grace windows.

### Vertical motion — `AscendCheck` / `GlideCheck` / `DescendCheck`
Vertical cheating is split into three independent checks (the old single `Flight` check is kept
but disabled, since a short strong "high jump" boost slipped under a hover-only rule):

* **Ascend** (up): flags gaining altitude beyond a legitimate jump. It is evaluated **only while
  airborne** (running into a wall keeps you grounded, where the engine auto-steps — that is the
  Step check's job, so grounded play is skipped entirely, which removes the wall false-positive).
  It uses a **windowed average** climb rate over `GainWindow`, not a single-frame `dy/dt`, so a
  one-sample step/teleport can't spike it. Flags when the average upward rate exceeds
  `jumpPower * MaxMultiplier` or the windowed climb exceeds `maxJumpHeight * GainMultiplier`
  (maxJumpHeight is derived from `jumpPower` and gravity, so it scales with the game).
* **Glide** (hover): flags staying airborne while barely falling (`|vy| < MaxDescent`) for
  `MinAirTime` (default 0.6s). A normal jump keeps vy above the threshold for only ~0.3s, so
  jumps are safe.
* **Descend** (controlled fall): flags falling but far slower than gravity should allow. It
  compares the real descent speed to `gravity * fallTime` (capped at terminal); below
  `ExpectedRatio` of that means a glide-down/parachute. A normal fall matches freefall.

All three are time-based (frame-rate independent), exempt the usual states/grace windows, and a
legitimate launcher (jump pad, cannon) can be whitelisted with the Coordinator's
`ExemptTeleport` API so fast upward leaps are not flagged.

### Timer (increased game speed) — `TimerCheck.Timer`
Roblox exposes no per-movement packets server-side, so the observable proxy is ground covered
per unit of **real** time. A rolling window tracks horizontal distance vs elapsed wall-clock
time; it only flags when the *sustained* rate exceeds `WalkSpeed * AllowedRatio` (default 110%+)
once the window is full. Isolated bursts never flag.

### Teleport — `TeleportCheck.Teleport`
Single-sample displacement against the maximum possible travel over the elapsed time, using
`WalkSpeed` for horizontal, `JumpPower` for upward and terminal velocity for downward, plus a
flat ping allowance. A "hard" overrun (4x the allowance) flags immediately; smaller overruns
must persist. Respawns, spawns, seat entry/exit and whitelisted game teleports are all covered
by the shared `exemptUntil` window.

---

### Step — `Movement/Step`
Flags being lifted vertically while **grounded** by more than the engine's legitimate step height
(`MaxStep`, default 2.75 studs) in one frame. Stairs/ramps produce small per-frame gains and
jumps leave the ground, so neither false-flags.

### Spider — `Movement/Spider`
Flags climbing a vertical wall without a ladder. Hybrid threading (like Phase): serial prep
builds the raycast exclusion, then four horizontal probes look for a nearby solid wall while the
player is airborne with upward speed. The climb must persist `MinSustain` (0.35s) so a jump
beside a wall is safe. Ladders set the Humanoid Climbing state (`state.climb`), which exempts.

### ThroughWall — `Combat/ThroughWall`
Validates melee line-of-sight. The game reports each resolved hit via `ReportHit`; this check
casts a ray between the two players (start/end offsets avoid their own bodies). If a solid,
collidable, non-character part blocks the path, the hit went through a wall and the attacker is
flagged.

### Velocity — `Combat/Velocity`
Anti-knockback. When the game applies knockback it reports the intended velocity via
`ReportKnockback` (which also stores the victim's position at hit time); the check measures the
victim's real sampled speed from that position over `Window` (0.35s), so the first sample
captures the impulse. If it never reaches `Ratio` (0.5×) of the intended knockback, the client
suppressed it -> flag. Before flagging, a short ray is cast from the victim along the knockback
direction: if a solid wall sits within `Room` studs the knockback was physically blocked and is
skipped (hitting a wall is not anti-knockback). Reduced knockback is a top-tier BedWars edge
(surviving near the void).

---

## 3b. The extended guards

Added on top of the original checks; each is still one `Actor` containing one `Script`. All
of them read the shared roster/config and push to the shared queue, exactly like the originals.

| Guard | Folder | Thread | Detects |
| --- | --- | --- | --- |
| Movement | `Movement/Movement` | parallel | CFrame-walk / move-with-no-velocity: windowed displacement vs the integral of `AssemblyLinearVelocity`. |
| FlyGuard | `Flight/FlyGuard` | parallel | PlatformStand fly / hover / illegal ascent (the states the FlightA-C checks exempt). |
| SwimGuard | `Flight/SwimGuard` | parallel | swim-in-air: the `Swimming` state while `FloorMaterial ~= Water`. |
| HumanoidGuard | `Player/HumanoidGuard` | parallel | WalkSpeed / JumpPower / JumpHeight / HipHeight / MaxSlopeAngle tamper vs the spawn baseline. |
| StateGuard | `Player/StateGuard` | parallel | Flying / StrafingNoPhysics state, seatless fake `Sit`. |
| IntegrityGuard | `Player/IntegrityGuard` | parallel | Dead/Freefall state disabled, Flying enabled (baseline-relative), extra Humanoids. |
| NoclipGuard | `Player/NoclipGuard` | parallel | HumanoidRootPart `CanCollide` off, HRP `NoCollisionConstraint`. |
| PhysicsGuard | `Player/PhysicsGuard` | parallel | Injected body movers / forces / constraints (`LineForce`, `BodyVelocity`, ...). |
| HealthGuard | `Player/HealthGuard` | parallel | MaxHealth tamper, Health > MaxHealth, illegal heal bursts. |
| HitboxGuard | `Player/HitboxGuard` | parallel | Inflated limbs / HRP / accessory handles vs the spawn baseline. |
| FlingGuard | `Combat/Fling` | parallel | Extreme HRP angular / linear velocity used to fling players. |
| Hit | `Combat/Hit` | parallel | Hit reach (+ping cushion), hit spam, kill-aura (too many distinct victims). LOS stays in `ThroughWall`. |
| FireRate | `Combat/FireRate` | parallel | Shot-rate limits, fed by the `ReportShot` API. |
| RemoteGuard | `Network/RemoteGuard` | serial sensor | Global + per-remote RemoteEvent spam, oversized/too-many-argument payloads. |
| ToolGuard | `Network/ToolGuard` | serial sensor | Tool equip / activate spam; auto-hooks every Tool that enters a character. |
| ExploitGuard | `Network/ExploitGuard` | serial sensor | Invocations of suspiciously-named remotes (`Checks.Exploit.Patterns`). |
| BanManager | `Core/Coordinator` | serial | Strikes -> warn / kick, idle strike decay, whitelist, session (+optional DataStore) rejoin ban. |

Notes:

* The property guards (Humanoid / Integrity / Hitbox) compare against a **spawn baseline**
  captured once per character, so engine defaults (e.g. non-collidable R15 limbs, a
  default-enabled `Flying` *state enable*) never false-flag; only a change from what the
  character spawned with is reported.
* The modern R15 rig's `BallSocketConstraint` / `AnimationConstraint` / `RigidConstraint`
  joints and accessory `NoCollisionConstraint`s are deliberately excluded from the physics /
  noclip scans; only movers, `LineForce`-style actuators and HRP-parented noclip constraints
  are counted.
* New bindables under `NanoAC-R`: `ReportShot(player, weapon)`, `ReportHeal(player, amount)`
  and `BanManager` (`Invoke("strike"|"whitelist"|"unban"|"isWhitelisted"|"isBanned", ...)`).
* Gameplay that legitimately changes humanoid properties should either set them before the
  spawn baseline is captured or whitelist the player (`BanManager` `whitelist` action / the
  `NanoAC_Whitelisted` attribute), which exempts them from every check.

## 4. Combat reporting API

```lua
local nano = game.ServerScriptService["NanoAC-R"]
nano.ReportHit:Invoke(attackerPlayer, victimPlayer)                 -- after you resolve a hit
nano.ReportKnockback:Invoke(victimPlayer, knockbackVelocityVector)  -- when you apply knockback
```
Both are `BindableFunction`s (server-side only) that capture positions/velocity and enqueue the
event; the Combat checks validate from the parallel phase. Without these calls the combat checks
simply stay idle.

## 5. Violations, alerts and setbacks (Coordinator, serial)

* Every confirmed violation increments that check's **VL**. VL decays continuously at
  `VL.DecayPerSecond`.
* When a check's VL crosses its threshold and the setback cooldown has elapsed:
  1. A chat alert is sent in the exact format
     `<username> failed <Check> VL:<times> Times`
     (e.g. `Builderman failed Speed VL:5 Times`). Staff-only by default.
  2. A **setback** teleports the player to the last verified safe, supported CFrame, zeroes
     their linear and angular velocity, and arms a cooldown + grace window so setbacks cannot
     loop. VLs keep rising if the player keeps failing.
* `Punish.KickAfterSetbacks > 0` kicks after N setbacks (placeholder hook).

### Staff detection
A player counts as staff if any of these is true: they carry the configured attribute
(`NanoAC_Staff`), their `UserId` is in `Alerts.StaffUserIds`, or their rank in
`Alerts.StaffGroupId` is `>= Alerts.MinGroupRank`. Set `Alerts.StaffOnly = false` to show alerts
to everyone in chat.

### ExemptTeleport API
Whitelist a legitimate teleport from any server script:

```lua
local nano = game.ServerScriptService["NanoAC-R"]
nano.ExemptTeleport:Invoke(player, 2) -- optional seconds; defaults to Settings.Grace.AfterTeleport
```

This sets the player's shared `exemptUntil`, so **all** checks skip them for that window.

---

## 5. Settings

All tuning lives in the `Settings` table at the top of `Coordinator.Coordinator`. It is the
single source of truth; the coordinator mirrors every numeric/boolean value into the
`NanoAC_Config` SharedTable, which the checks read from parallel threads.

| Section | What it controls |
| --- | --- |
| `Enabled` / `Debug` | master switch, verbose console output |
| `Alerts` | on/off, staff-only, colour, staff ids/group/attribute |
| `Grace` | spawn / teleport / setback / seat grace windows (seconds) |
| `VL` | per-second decay, alert display cap |
| `Setback` | enable + per-player cooldown |
| `Punish` | kick-after-N-setbacks hook |
| `Checks.<Name>` | per-check `Enabled`, `VLThreshold`, `RequiredStreak`, `EmitCooldown` and the check-specific tolerances |

Checks read their thresholds with `Shared.cfg("key", default)`, so even if the coordinator is
edited, the checks fall back to sane defaults.

---

## 6. Building the hierarchy in Studio (from scratch)

1. In `ServerScriptService`, create an `Actor` named **`NanoAC-R`**.
2. Add a `ModuleScript` named **`NanoShared`** directly under it.
3. Inside `NanoAC-R`, create six `Actor`s named **`Coordinator`**, **`PhaseCheck`**,
   **`SpeedCheck`**, **`FlightCheck`**, **`TimerCheck`**, **`TeleportCheck`**.
4. Under each actor add one `Script`, named (respectively) **`Coordinator`**, **`Phase`**,
   **`Speed`**, **`Flight`**, **`Timer`**, **`Teleport`**.
5. Paste the corresponding source into each script.
6. Under `NanoAC-R`, add a `BindableFunction` named **`ExemptTeleport`** (the coordinator also
   creates it at runtime if absent).
7. In `ReplicatedStorage`, add a `RemoteEvent` named **`NanoAC_AlertEvent`**.
8. In `StarterPlayer.StarterPlayerScripts`, add a `LocalScript` named
   **`NanoAC_AlertClient`** and paste the client displayer.
9. Set `Settings.Alerts.StaffUserIds` (or the staff group / attribute) so alerts reach staff.

> All of the containers and both runtime instances are already present in this place; the
> `ExemptTeleport` bindable and `NanoAC_AlertEvent` remote are created automatically if missing.

---

## 7. Verified behaviour

Tested in Studio (Play Solo) on this place:

* The coordinator samples the player every `PostSimulation` and publishes the roster/config.
* Running across the baseplate produced **zero** false violations (`queue.write == queue.read`).
* Injecting ten `Speed` violations drove VL to the threshold, which produced the chat alert
  `enderswords_198 failed Speed VL:10 Times` on the client and a setback to the last safe spot.
* The queue drained every frame (`write == read`) and no `[NanoAC-R] ... error` lines appeared.
* `/speed on` + holding W produced sustained `Speed` (~50-65, allowed 22.4) and `Timer`
  (sustained ~38, allowed 17.9) flags with ~2.7 setbacks/second.
* `/fly on` produced continuous `Flight` flags (VL climbing, `... VL:8 Times` alerts).

---

## 8. Temporary test mode (currently ON)

These were added to make the anti-cheat easy to exercise and are all easy to revert:

| Toggle | Value now | Production value |
| --- | --- | --- |
| `Alerts.EveryoneIsStaff` | `true` — every player receives threshold alerts | `false` |
| `Setback.OnEveryFlag` | `true` — ANY flag triggers a setback, not just threshold crossings | `true` (default) |
| `Setback.FreezeSafeSpotOnFlag` | `true` — stop advancing the safe spot while a player is flagged | keep / optional |
| `Setback.Cooldown` | `0.2s` | `1.5s` |
| `Grace.AfterSetback` | `0.25s` — short check-blindness after a setback | `1.0s` |
| `Checks.*.RequiredStreak` / `EmitCooldown` | lowered (Speed 3/0.25, Timer 2/0.35, Phase 1/0.3, Teleport 1/0.4) | higher |

### Chat commands

The chat test commands are **disabled for shipping**. `/verbose` is gated by
`Verbose.AllowSelfToggle` (default `false`) and `/velocity` by `Settings.Debug` (default
`false`); the client-side `/speed` and `/fly` hacks have been removed entirely.

| Command | Effect |
| --- | --- |
| `/verbose` | (off by default) toggles raw per-flag output **for that player** when `Verbose.AllowSelfToggle = true` |
| `/velocity <amount> <left\|right\|up\|down\|forward\|back> [fake]` | (off by default) when `Debug = true`, applies/report a knockback for testing |

### Test map

`Workspace.NanoAC_TestMap` is a labelled test ground (anticheat-test.com style), around
`(200, 0, 0)`: **Speed/Timer lane**, **Spider wall** (+ Ladder for the exempt case), **Step blocks**
(1–4 studs), **Teleport gap** (20 studs), **Fly target** (y=60), **Velocity pad**, and a
**Through-wall** wall with pads on each side. It is a plain Folder of anchored parts; move or
rebuild it freely.

`/velocity` is handled by the Coordinator (`Player.Chatted`, debug-only); `/verbose` too. The
commands are hidden from chat via `TextChatService.OnIncomingMessage` (which can only be
**set**, never read). Movement is driven on the client — the character's network owner — so the
server genuinely observes it; boosting `Humanoid.WalkSpeed` from the server would NOT work
because the checks read `WalkSpeed` as their baseline.

---

## 10. Building & sharing (Rojo)

Sources live on disk in a Rojo project:

```
default.project.json      maps src/ into the DataModel
rokit.toml                toolchain pin (rojo)
src/server/NanoAC-R/      the Actor tree (Actor + BindableFunctions + Core/Movement/Flight/Combat)
src/client/               NanoAC_AlertClient.client.luau
```

Mapping notes:
- `src/server/NanoAC-R/init.meta.json` (`{"className":"Actor"}`) makes the folder an **Actor**.
- Each check folder has an `init.meta.json` Actor + `<Name>.server.luau` (the Script).
- `ExemptTeleport/ReportHit/ReportKnockback.meta.json` are `BindableFunction`s.
- The `NanoAC_AlertEvent` RemoteEvent is **not** in the project — the Coordinator creates it at
  runtime if missing, so no extra instance is needed.

Build / sync:
```bash
rokit install                 # or: cargo install rojo  / download the rojo binary
rojo serve                    # then connect with the Rojo Studio plugin and Sync
rojo build -o NanoAC-R.rbxlx  # produce a place file you can share
```

To install for someone: `rojo build` a place (or hand them the repo and have them `rojo serve`),
or use **Option A** from the sharing notes — export the `NanoAC-R` Actor to an `.rbxmx` and drop
it in `ServerScriptService`.

Notes:
- **Test-only pieces are not in the Rojo project**: `Workspace.NanoAC_TestMap` and the client
  test commands (`/speed`, `/fly`; `/velocity`/`/verbose` on the server) — delete the test
  section from `NanoAC_AlertClient` before shipping.
- **Defaults**: `Setback.OnEveryFlag = true` (any flag sets the player back, subject to the
  `Setback.Cooldown`), `Setback.Cooldown = 1.5`, `Grace.AfterSetback = 1.0`, standard check
  streaks/cooldowns, `Alerts.EveryoneIsStaff = false` (alerts go to staff only). Add your
  UserId to `Alerts.StaffUserIds` (or set the `NanoAC_Staff` attribute) to receive alerts.

