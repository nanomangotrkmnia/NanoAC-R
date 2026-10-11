--[[
	NanoAC-R | client: alerts

	Receives NanoAC_AlertEvent and renders it as a chat system message.

	(The former client-side test hacks -- /speed and /fly -- have been removed for shipping.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

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
