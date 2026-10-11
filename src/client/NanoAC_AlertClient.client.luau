--[[
	NanoAC-R | client: alerts + TEST commands

	Alert display : receives NanoAC_AlertEvent and renders it as a chat system message.
	Test commands : typed in chat, hidden from chat, and applied locally:
	                  /speed on|off  -> move at TEST_SPEED_MULT x normal speed
	                  /fly   on|off  -> move at TEST_SPEED_MULT x normal speed and ascend
	                Both exceed the checks' thresholds (>= 1.2x normal). Movement is driven on the
	                client (the character's network owner) so the server genuinely observes it.
	                Remove this TEST section before shipping.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

-- =====================================================================================
--  ALERT DISPLAY
-- =====================================================================================
local alertEvent = ReplicatedStorage:WaitForChild("NanoAC_AlertEvent", 30)

local function show(text, color)
	local shown = false
	pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		if channels then
			local general = channels:FindFirstChild("RBXGeneral")
				or channels:FindFirstChildWhichIsA("TextChannel")
			if general then
				general:DisplaySystemMessage(tostring(text))
				shown = true
			end
		end
	end)
	if not shown then
		pcall(function()
			StarterGui:SetCore("ChatMakeSystemMessage", {
				Text = tostring(text),
				Color = color or Color3.fromRGB(255, 85, 85),
				Font = Enum.Font.SourceSansBold,
			})
		end)
	end
end

if alertEvent then
	alertEvent.OnClientEvent:Connect(show)
end

-- =====================================================================================
--  TEST COMMANDS  (remove before shipping)
-- =====================================================================================
local TEST_SPEED_MULT = 1.5  -- >= 1.2x normal; clears Speed's 1.4x slack and Timer's 1.12x
local FLY_UP_SPEED = 30      -- studs/s of lift while holding Space

local test = { speed = false, fly = false }

local function rootPart()
	local c = Players.LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
	local c = Players.LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

-- A LinearVelocity mover is used for fly so the humanoid does not fight the motion.
local flyMover = nil
local function destroyMover()
	if flyMover then
		flyMover:Destroy()
		flyMover = nil
	end
end
local function ensureMover(r)
	if flyMover and flyMover.Parent == r then
		return flyMover
	end
	destroyMover()
	local att = Instance.new("Attachment")
	att.Name = "NanoAC_FlyAtt"
	att.Parent = r
	local lv = Instance.new("LinearVelocity")
	lv.Name = "NanoAC_Fly"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = 1e6
	lv.VectorVelocity = Vector3.zero
	lv.Parent = r
	flyMover = lv
	return lv
end

RunService.Heartbeat:Connect(function(dt)
	local r = rootPart()
	local h = humanoid()
	if not r or not h then
		destroyMover()
		return
	end
	local walk = (h.WalkSpeed > 0) and h.WalkSpeed or 16
	if test.fly then
		-- Meteor-style: hold Space to ascend; otherwise hover (vertical velocity held at 0).
		local lv = ensureMover(r)
		local dir = h.MoveDirection
		local horiz = (dir.Magnitude > 0.05) and dir.Unit or Vector3.zero
		local ascend = (UserInputService:IsKeyDown(Enum.KeyCode.Space) or h.Jump) and FLY_UP_SPEED or 0
		if lv then
			lv.VectorVelocity = horiz * (walk * TEST_SPEED_MULT) + Vector3.new(0, ascend, 0)
		end
	else
		destroyMover()
		if test.speed then
			local dir = h.MoveDirection
			if dir.Magnitude >= 0.05 then
				r.CFrame = r.CFrame + dir.Unit * (walk * TEST_SPEED_MULT * dt)
			end
		end
	end
end)

-- OnIncomingMessage can only be SET (not read), so bind it once and do not chain.
pcall(function()
	TextChatService.OnIncomingMessage = function(message)
		local text = message.Text
		local source = message.TextSource
		if typeof(text) == "string" and source and source.UserId == Players.LocalPlayer.UserId then
			local cmd, arg = text:lower():match("^%s*/(%a+)%s*(%a*)")
			if cmd == "verbose" then
				local props = Instance.new("TextChatMessageProperties")
				props.Text = ""
				return props -- the server handles the toggle
			elseif cmd == "speed" then
				test.speed = (arg == "on")
				test.fly = false
				print("[NanoAC-R test] speed = " .. tostring(test.speed))
				local props = Instance.new("TextChatMessageProperties")
				props.Text = ""
				return props
			elseif cmd == "fly" then
				test.fly = (arg == "on")
				test.speed = false
				print("[NanoAC-R test] fly = " .. tostring(test.fly))
				local props = Instance.new("TextChatMessageProperties")
				props.Text = ""
				return props
			elseif cmd == "velocity" then
				local props = Instance.new("TextChatMessageProperties")
				props.Text = ""
				return props -- handled server-side
			end
		end
		return nil
	end
end)
