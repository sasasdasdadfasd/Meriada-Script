--!nonstrict
-- Meriada.lua  (stage 1: custom menu + Auto Block / Auto Parry)  Luau, Roblox client executor.
-- Replaces AutoBlock.lua. RemoteSpy.lua is still used to find the block remote.
-- Game-specific values (attack animation IDs, timings, block remote) are unknown (nil) until you fill them in.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local env = (getgenv and getgenv()) or _G
if env.__MeriadaUnload then
	pcall(env.__MeriadaUnload)
end
if env.__AeroAutoBlockUnload then -- old standalone AutoBlock.lua
	pcall(env.__AeroAutoBlockUnload)
end

---------------------------------------------------------------------
-- CONFIG  (nil = unknown / not set; "uncalibrated" = starting value, tune in game)
-- Most of these can be changed from the Settings tab; this table holds the starting values.
---------------------------------------------------------------------
local Config = {
	ExpectedPlaceId = nil, -- set to the PlaceId printed at startup; the script refuses to run on a mismatch

	DetectMode = "event", -- "event" = Animator.AnimationPlayed, "poll" = GetPlayingAnimationTracks each Heartbeat
	Learn = false,        -- log nearby players' animations (id, length, keyframes) to the console
	LearnRange = 60,
	LearnIgnoreLooped = true,

	MaxDistance = 5,      -- studs between root parts, adjustable 1-30; per-attack override: entry.Range
	Trigger = "any",      -- "list": only animations in Attacks | "any": any attack-like animation (heuristic) + Attacks
	AnyMinPriority = "Idle", -- any-mode filter: ignores animations below this priority and looped ones, uncalibrated
	AnyDelay = 0,         -- seconds after the animation starts before F is pressed in any-mode, uncalibrated
	HoldTime = 0.5,       -- seconds F is held for a block (0.1 - 1.5), uncalibrated
	Reactive = true,      -- press F when you take damage and the proactive block was too late
	ReactiveRange = 12,   -- studs; only react to damage if another player is this close (filters fall damage), uncalibrated
	Ignore = {},          -- animation IDs (strings) that any-mode must never react to, e.g. ["123"] = true
	InputMethod = "both", -- key mode: "vim" (VirtualInputManager), "keypress" (executor keypress/keyrelease) or "both"
	IncludeNpcs = true,   -- also watch Humanoids that are not player characters (NPCs, dummies)
	FacingCheck = true,
	FacingDot = 0.3,      -- uncalibrated
	CompensatePing = true,
	TapTime = 0.05,       -- seconds a parry tap is held, uncalibrated
	MaxHold = 3,
	IgnoreTeammates = true,

	-- How the block/parry is produced. Mode and Key are set from Settings > Block input.
	Block = {
		Mode = "key",     -- "key" (VirtualInputManager) or "remote"
		Key = Enum.KeyCode.F, -- in-game block button (told by the user: F)
		Remote = nil,     -- remote mode only: function() return <RemoteEvent|RemoteFunction> end
		BuildArgs = nil,  -- remote mode only: function(entry, phase) return { ... } end, phase = "start" | "stop"
	},

	-- Keyed by numeric animation ID as a string (from Learn mode).
	--   Kind  = "block" or "parry" (required): decides which menu feature controls the entry
	--   Delay = seconds from animation start until the input must be pressed (required)
	--   Hold  = nil (block: Config.HoldTime, parry: tap) | number | "track" (hold while the animation plays)
	--   Range = optional per-attack distance override
	--   RequirePlaying = false to still fire if the track already stopped
	Attacks = {
		-- ["123456789"] = { Kind = "parry", Delay = 0.25 },
		-- ["987654321"] = { Kind = "block", Delay = 0.10 },
	},
}

local State = { AutoBlock = false, AutoParry = false }
local Alive = true
local connections = {}
local Unload -- assigned below

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local LocalPlayer = Players.LocalPlayer

if Config.ExpectedPlaceId and game.PlaceId ~= Config.ExpectedPlaceId then
	warn(("[Meriada] PlaceId mismatch: expected %d, got %d. Not running."):format(Config.ExpectedPlaceId, game.PlaceId))
	return
end
print(("[Meriada] PlaceId=%d GameId=%d"):format(game.PlaceId, game.GameId))

---------------------------------------------------------------------
-- COMBAT CORE
---------------------------------------------------------------------
local charConns = {}  -- [player] = connections of the current character
local animators = {}  -- [player] = { char, animator, playing }
local pressed = nil   -- release function while a block is held
local busy = false
local warned = {}

local VIM = nil
do
	local ok, svc = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if ok then
		VIM = svc
	end
end

local function warnOnce(key, msg)
	if not warned[key] then
		warned[key] = true
		warn("[Meriada] " .. msg)
	end
end

local function animKey(animation)
	if not animation then
		return nil
	end
	return string.match(animation.AnimationId, "%d+")
end

local function getRoot(char)
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function isAlive(char)
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- returns true, or false plus a short reason (printed in Learn mode)
local function isThreat(attackerChar, maxDist)
	local myChar = LocalPlayer.Character
	local myRoot, theirRoot = getRoot(myChar), getRoot(attackerChar)
	if not (myRoot and theirRoot and isAlive(myChar)) then
		return false, "my character or the attacker has no HumanoidRootPart / I am dead"
	end
	local offset = myRoot.Position - theirRoot.Position
	local dist = offset.Magnitude
	if dist ~= dist or dist > maxDist then
		return false, ("too far: %.1f studs > max %.1f"):format(dist, maxDist)
	end
	if Config.FacingCheck and dist > 0.001 then
		local dot = theirRoot.CFrame.LookVector:Dot(offset / dist)
		if dot < Config.FacingDot then
			return false, ("attacker not facing me: dot %.2f < %.2f"):format(dot, Config.FacingDot)
		end
	end
	return true
end

-- key is a Player, or a Model for NPCs
local function isIgnored(key)
	if typeof(key) ~= "Instance" or not key:IsA("Player") then
		return not Config.IncludeNpcs
	end
	return Config.IgnoreTeammates and LocalPlayer.Team ~= nil and key.Team == LocalPlayer.Team
end

local function blockConfigured()
	local B = Config.Block
	if B.Mode == "key" then
		return (VIM ~= nil or (keypress ~= nil and keyrelease ~= nil)) and typeof(B.Key) == "EnumItem"
	elseif B.Mode == "remote" then
		return type(B.Remote) == "function" and type(B.BuildArgs) == "function"
	end
	return false
end

-- Enum.KeyCode value -> Windows virtual key code (letters and digits only)
local function toVirtualKey(keyCode)
	local v = keyCode.Value
	if v >= 97 and v <= 122 then
		return v - 32
	end
	if v >= 48 and v <= 57 then
		return v
	end
	return nil
end

local function sendKey(down)
	local key = Config.Block.Key
	local method = Config.InputMethod
	local sent = {}
	if (method == "vim" or method == "both") and VIM then
		local ok = pcall(function()
			VIM:SendKeyEvent(down, key, false, game)
		end)
		if ok then
			table.insert(sent, "vim")
		end
	end
	if (method == "keypress" or method == "both") and keypress and keyrelease then
		local vk = toVirtualKey(key)
		if vk then
			local ok = pcall(down and keypress or keyrelease, vk)
			if ok then
				table.insert(sent, "keypress")
			end
		end
	end
	if #sent == 0 then
		error(("no input method worked (VIM=%s, keypress=%s)"):format(tostring(VIM ~= nil), tostring(keypress ~= nil)))
	end
	if Config.Learn then
		print(("[Meriada:learn] key %s %s via %s"):format(key.Name, down and "down" or "up", table.concat(sent, "+")))
	end
end

local function setBlock(down, entry)
	local B = Config.Block
	if B.Mode == "key" then
		sendKey(down)
	elseif B.Mode == "remote" then
		local remote = B.Remote()
		local args = B.BuildArgs(entry, down and "start" or "stop")
		if typeof(remote) ~= "Instance" or type(args) ~= "table" then
			error("Remote() must return an Instance and BuildArgs() a table")
		end
		if remote:IsA("RemoteFunction") then
			remote:InvokeServer(table.unpack(args))
		else
			remote:FireServer(table.unpack(args))
		end
	end
end

local function kindEnabled(kind)
	return (kind == "block" and State.AutoBlock) or (kind == "parry" and State.AutoParry)
end

local function execute(entry, track)
	if busy then
		return
	end
	busy = true
	local ok, err = pcall(setBlock, true, entry)
	if not ok then
		busy = false
		warnOnce("startfail", "block start failed: " .. tostring(err))
		return
	end
	pressed = function()
		local rok, rerr = pcall(setBlock, false, entry)
		if not rok then
			warnOnce("stopfail", "block release failed: " .. tostring(rerr))
		end
	end

	local hold = entry.Hold
	if hold == nil and entry.Kind == "block" then
		hold = Config.HoldTime
	end
	if hold == "track" and track then
		local t0 = os.clock()
		while Alive and kindEnabled(entry.Kind) and track.IsPlaying and os.clock() - t0 < Config.MaxHold do
			task.wait()
		end
	elseif type(hold) == "number" then
		task.wait(math.min(hold, Config.MaxHold))
	else
		task.wait(Config.TapTime)
	end

	if pressed then
		local release = pressed
		pressed = nil
		release()
	end
	busy = false
end

local function learnLog(player, char, track, id)
	if Config.LearnIgnoreLooped and track.Looped then
		return
	end
	local myRoot, theirRoot = getRoot(LocalPlayer.Character), getRoot(char)
	if not (myRoot and theirRoot) then
		return
	end
	local dist = (myRoot.Position - theirRoot.Position).Magnitude
	if dist > Config.LearnRange then
		return
	end
	print(("[Meriada:learn] %s id=%s name=%s len=%.3f looped=%s prio=%s dist=%.1f"):format(
		player.Name, id, track.Name, track.Length, tostring(track.Looped), tostring(track.Priority), dist))
	local t0 = os.clock() - track.TimePosition
	local c = track.KeyframeReached:Connect(function(name)
		print(("[Meriada:learn]   id=%s keyframe=%s at %.3fs"):format(id, name, os.clock() - t0))
	end)
	track.Stopped:Once(function()
		c:Disconnect()
	end)
	return dist
end

-- any-mode heuristic: a non-looped animation at or above AnyMinPriority (Core is excluded)
local function anyModeAccepts(track, id)
	if Config.Ignore[id] or track.Looped then
		return false
	end
	local pv = track.Priority.Value
	return pv >= Enum.AnimationPriority[Config.AnyMinPriority].Value and pv < Enum.AnimationPriority.Core.Value
end

local function handleTrack(player, char, track, elapsed)
	local id = animKey(track.Animation)
	if not id then
		return
	end
	local watched = nil -- distance if Learn mode logged this animation (non-looped, within LearnRange)
	if Config.Learn then
		watched = learnLog(player, char, track, id)
	end
	local function why(msg)
		if watched then
			print(("[Meriada:learn]   skip id=%s (%s): %s"):format(id, player.Name, msg))
		end
	end
	local entry = Config.Attacks[id]
	if not entry and Config.Trigger == "any" and anyModeAccepts(track, id) then
		entry = { Kind = "block", Delay = Config.AnyDelay }
	end
	if not entry then
		if Config.Trigger == "list" then
			why("Trigger is \"list\" and this id is not in Attacks")
		else
			why(("any-mode filter: looped=%s, priority=%s (min %s), ignored=%s"):format(
				tostring(track.Looped), track.Priority.Name, Config.AnyMinPriority, tostring(Config.Ignore[id] == true)))
		end
		return
	end
	local kind = entry.Kind
	if kind ~= "block" and kind ~= "parry" then
		warnOnce("kind" .. id, "Attacks[" .. id .. "].Kind must be \"block\" or \"parry\". Skipping.")
		return
	end
	if not kindEnabled(kind) then
		why(("Auto %s is OFF (turn it on in Combat)"):format(kind == "block" and "Block" or "Parry"))
		return
	end
	if not blockConfigured() then
		warnOnce("cfg", "Block input is not configured (Settings > Block input). Detecting only, not blocking.")
		return
	end
	if type(entry.Delay) ~= "number" then
		warnOnce("delay" .. id, "Attacks[" .. id .. "].Delay is not set. Skipping.")
		return
	end

	local ping = 0
	if Config.CompensatePing then
		local ok, p = pcall(function()
			return LocalPlayer:GetNetworkPing()
		end)
		if ok and type(p) == "number" then
			ping = p
		end
	end
	local wait_ = math.max(0, entry.Delay - elapsed - ping)

	task.delay(wait_, function()
		if not Alive or not kindEnabled(kind) or not char.Parent then
			return
		end
		if entry.RequirePlaying ~= false and not track.IsPlaying then
			why("animation already stopped before the delay elapsed")
			return
		end
		local threat, reason = isThreat(char, entry.Range or Config.MaxDistance)
		if not threat then
			why(reason)
			return
		end
		if Config.Learn then
			print(("[Meriada:learn] %s trigger: %s id=%s attacker=%s"):format(kind, kind == "block" and "F" or "tap", id, player.Name))
		end
		execute(entry, track)
	end)
end

local function clearChar(player)
	local list = charConns[player]
	if list then
		for _, c in list do
			c:Disconnect()
		end
	end
	charConns[player] = nil
	animators[player] = nil
end

local function hookCharacter(player, char)
	clearChar(player)
	local list = {}
	charConns[player] = list
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		if not hum or charConns[player] ~= list then
			return
		end
		local animator = hum:WaitForChild("Animator", 10)
		if not animator or charConns[player] ~= list then
			return
		end
		animators[player] = { char = char, animator = animator, playing = {} }
		table.insert(list, animator.AnimationPlayed:Connect(function(track)
			if Config.DetectMode == "event" and not isIgnored(player) then
				handleTrack(player, char, track, track.TimePosition)
			end
		end))
	end)
end

local function hookPlayer(player)
	if player == LocalPlayer then
		return
	end
	connect(player.CharacterAdded, function(char)
		hookCharacter(player, char)
	end)
	connect(player.CharacterRemoving, function()
		clearChar(player)
	end)
	if player.Character then
		hookCharacter(player, player.Character)
	end
end

for _, p in Players:GetPlayers() do
	hookPlayer(p)
end
connect(Players.PlayerAdded, hookPlayer)
connect(Players.PlayerRemoving, clearChar)

-- NPCs: any Humanoid in the workspace that is not a player character
local function hookNpc(hum)
	local model = hum.Parent
	if not model or model == LocalPlayer.Character or Players:GetPlayerFromCharacter(model) or charConns[model] then
		return
	end
	hookCharacter(model, model)
	local list = charConns[model]
	if list then
		table.insert(list, model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				clearChar(model)
			end
		end))
	end
end
connect(workspace.DescendantAdded, function(d)
	if d:IsA("Humanoid") then
		task.defer(hookNpc, d)
	end
end)
task.spawn(function()
	for _, d in workspace:GetDescendants() do
		if d:IsA("Humanoid") then
			hookNpc(d)
		end
	end
end)

-- reactive block: you took damage while a player is close and no block was up, so hold F right away
local reactiveConns = {}
local function clearReactive()
	for _, c in reactiveConns do
		c:Disconnect()
	end
	table.clear(reactiveConns)
end

local function nearbyPlayer(range)
	local myRoot = getRoot(LocalPlayer.Character)
	if not myRoot then
		return false
	end
	for key, info in animators do
		if not isIgnored(key) and isAlive(info.char) then
			local root = getRoot(info.char)
			if root and (root.Position - myRoot.Position).Magnitude <= range then
				return true
			end
		end
	end
	return false
end

local function hookLocalCharacter(char)
	clearReactive()
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		if not hum or LocalPlayer.Character ~= char then
			return
		end
		local last = hum.Health
		table.insert(reactiveConns, hum.HealthChanged:Connect(function(h)
			local dropped = h < last - 0.01
			last = h
			if not dropped or h <= 0 then
				return
			end
			if not (Alive and State.AutoBlock and Config.Reactive) or busy or not blockConfigured() then
				return
			end
			if not nearbyPlayer(Config.ReactiveRange) then
				return
			end
			if Config.Learn then
				print("[Meriada:learn] reactive block: damage taken")
			end
			task.spawn(execute, { Kind = "block" }, nil)
		end))
	end)
end
connect(LocalPlayer.CharacterAdded, hookLocalCharacter)
if LocalPlayer.Character then
	hookLocalCharacter(LocalPlayer.Character)
end

connect(RunService.Heartbeat, function()
	if Config.DetectMode ~= "poll" then
		return
	end
	for player, info in animators do
		if not isIgnored(player) then
			local now = {}
			for _, track in info.animator:GetPlayingAnimationTracks() do
				now[track] = true
				if not info.playing[track] then
					handleTrack(player, info.char, track, track.TimePosition)
				end
			end
			info.playing = now
		end
	end
end)

---------------------------------------------------------------------
-- UI: THEME + HELPERS
---------------------------------------------------------------------
local Theme = {
	Accent = Color3.fromRGB(150, 90, 255),
	Bg = Color3.fromRGB(13, 11, 21),
	Panel = Color3.fromRGB(20, 17, 32),
	Panel2 = Color3.fromRGB(28, 24, 44),
	Off = Color3.fromRGB(52, 47, 74),
	Text = Color3.fromRGB(238, 235, 250),
	Muted = Color3.fromRGB(150, 144, 178),
	AnimateTitle = true,
}

local AccentPresets = {
	{ Name = "Violet", Color = Color3.fromRGB(150, 90, 255) },
	{ Name = "Magenta", Color = Color3.fromRGB(214, 84, 255) },
	{ Name = "Pink", Color = Color3.fromRGB(255, 105, 180) },
	{ Name = "Red", Color = Color3.fromRGB(255, 80, 100) },
	{ Name = "Orange", Color = Color3.fromRGB(255, 150, 70) },
	{ Name = "Emerald", Color = Color3.fromRGB(60, 220, 150) },
	{ Name = "Cyan", Color = Color3.fromRGB(70, 200, 255) },
	{ Name = "Blue", Color = Color3.fromRGB(90, 130, 255) },
}

local accentHooks = {}
local function onAccent(fn)
	table.insert(accentHooks, fn)
	fn(Theme.Accent)
end
local function setAccent(c)
	Theme.Accent = c
	for _, fn in accentHooks do
		fn(c)
	end
end
local function accentSeq(a)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, a),
		ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, a),
	})
end

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in props do
		inst[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
local function corner(p, r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) }, p)
end

local orders = {}
local function nextOrder(parent)
	orders[parent] = (orders[parent] or 0) + 1
	return orders[parent]
end

local Registry = {} -- [id] = { get, set } for save/load
local function register(id, get, set)
	if id then
		Registry[id] = { get = get, set = set }
	end
end

---------------------------------------------------------------------
-- UI: WINDOW
---------------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "Meriada",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	DisplayOrder = 999,
})
pcall(function()
	if syn and syn.protect_gui then
		syn.protect_gui(gui)
	end
end)
do
	local ok = pcall(function()
		if gethui then
			gui.Parent = gethui()
		else
			gui.Parent = game:GetService("CoreGui")
		end
	end)
	if not ok or not gui.Parent then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
end

local main = new("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(620, 420),
	BackgroundColor3 = Theme.Bg,
	BorderSizePixel = 0,
	Active = true,
}, gui)
corner(main, 12)
local scale = new("UIScale", { Scale = 1 }, main)
local stroke = new("UIStroke", {
	Thickness = 1.5,
	Color = Color3.new(1, 1, 1),
	ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, main)
local strokeGrad = new("UIGradient", {}, stroke)

local sidebar = new("Frame", {
	Size = UDim2.new(0, 160, 1, 0),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
}, main)
corner(sidebar, 12)
new("Frame", {
	Size = UDim2.new(0, 12, 1, 0),
	Position = UDim2.new(1, -12, 0, 0),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
}, sidebar)

local title = new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 64),
	BackgroundTransparency = 1,
	Text = "Meriada",
	Font = Enum.Font.GothamBlack,
	TextSize = 28,
	TextColor3 = Color3.new(1, 1, 1),
}, sidebar)
local titleGrad = new("UIGradient", {}, title)
onAccent(function(c)
	strokeGrad.Color = accentSeq(c)
	titleGrad.Color = accentSeq(c)
end)

local tabList = new("Frame", {
	Position = UDim2.fromOffset(0, 72),
	Size = UDim2.new(1, 0, 1, -110),
	BackgroundTransparency = 1,
}, sidebar)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabList)
new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, tabList)

new("TextLabel", {
	Position = UDim2.new(0, 0, 1, -30),
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Text = "stage 1 - combat",
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = Theme.Muted,
}, sidebar)

local content = new("Frame", {
	Position = UDim2.fromOffset(160, 0),
	Size = UDim2.new(1, -160, 1, 0),
	BackgroundTransparency = 1,
}, main)
local headerLabel = new("TextLabel", {
	Position = UDim2.fromOffset(20, 14),
	Size = UDim2.new(1, -80, 0, 28),
	BackgroundTransparency = 1,
	Text = "",
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	TextColor3 = Theme.Text,
}, content)
local pages = new("Frame", {
	Position = UDim2.fromOffset(0, 56),
	Size = UDim2.new(1, 0, 1, -56),
	BackgroundTransparency = 1,
}, content)

local dragZone = new("Frame", {
	Size = UDim2.new(1, 0, 0, 56),
	BackgroundTransparency = 1,
	Active = true,
	ZIndex = 5,
}, main)
local closeBtn = new("TextButton", {
	Position = UDim2.new(1, -40, 0, 14),
	Size = UDim2.fromOffset(26, 26),
	BackgroundColor3 = Theme.Panel2,
	Text = "X",
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = Theme.Muted,
	AutoButtonColor = false,
	ZIndex = 6,
}, main)
corner(closeBtn, 6)

local function setMenuVisible(v)
	main.Visible = v
	if v then
		scale.Scale = 0.94
		TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end
connect(closeBtn.MouseButton1Click, function()
	setMenuVisible(false)
end)

-- toast (independent of the menu so hotkey toggles are visible while the menu is closed)
local toast = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -40),
	Size = UDim2.fromOffset(260, 30),
	BackgroundColor3 = Theme.Panel2,
	BackgroundTransparency = 1,
	TextTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	TextColor3 = Theme.Text,
	Text = "",
}, gui)
corner(toast, 8)
local toastToken = 0
local function notify(text)
	toastToken += 1
	local mine = toastToken
	toast.Text = text
	TweenService:Create(toast, TweenInfo.new(0.15), { BackgroundTransparency = 0.1, TextTransparency = 0 }):Play()
	task.delay(1.6, function()
		if Alive and toastToken == mine then
			TweenService:Create(toast, TweenInfo.new(0.3), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
		end
	end)
end

-- dragging + slider drag + keybind capture (one set of global handlers)
local dragging, dragStart, startPos = false, nil, nil
local activeSlider = nil
local listening = nil
local keybinds = {}

local function isPointer(i)
	return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
end

connect(dragZone.InputBegan, function(i)
	if isPointer(i) then
		dragging, dragStart, startPos = true, i.Position, main.Position
	end
end)
connect(UserInputService.InputChanged, function(i)
	local moved = i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch
	if not moved then
		return
	end
	if dragging then
		local d = i.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
	if activeSlider then
		activeSlider.update(i.Position.X)
	end
end)
connect(UserInputService.InputEnded, function(i)
	if isPointer(i) then
		dragging = false
		activeSlider = nil
	end
end)
connect(UserInputService.InputBegan, function(input, processed)
	if listening then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local target = listening
			listening = nil
			target.set(input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode or nil)
		end
		return
	end
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	for _, kb in keybinds do
		if kb.Key and kb.Key == input.KeyCode and kb.fire then
			kb.fire()
		end
	end
end)

-- animation loop: title shimmer, border gradient, status refresh
local statusClock = 0
local refreshStatus -- assigned after the Combat tab exists
local t0 = os.clock()
connect(RunService.Heartbeat, function(dt)
	local t = os.clock() - t0
	titleGrad.Offset = Theme.AnimateTitle and Vector2.new(math.sin(t * 1.4), 0) or Vector2.new(0, 0)
	strokeGrad.Rotation = (t * 45) % 360
	statusClock += dt
	if statusClock > 0.5 then
		statusClock = 0
		if refreshStatus and main.Visible then
			refreshStatus()
		end
	end
end)

---------------------------------------------------------------------
-- UI: TABS + WIDGETS
---------------------------------------------------------------------
local tabs = {}
local function selectTab(tab)
	for _, t in tabs do
		local on = t == tab
		t.Page.Visible = on
		t.Bar.Visible = on
		t.Button.BackgroundTransparency = on and 0 or 1
		t.Label.TextColor3 = on and Theme.Text or Theme.Muted
	end
	headerLabel.Text = tab.Name
end

local function addTab(name)
	local btn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = Theme.Panel2,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = #tabs + 1,
	}, tabList)
	corner(btn, 8)
	local bar = new("Frame", {
		Size = UDim2.fromOffset(3, 18),
		Position = UDim2.new(0, 6, 0.5, -9),
		BorderSizePixel = 0,
		Visible = false,
	}, btn)
	corner(bar, 2)
	local lbl = new("TextLabel", {
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(1, -18, 1, 0),
		BackgroundTransparency = 1,
		Text = name,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Theme.Muted,
	}, btn)
	local page = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
	}, pages)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, page)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		PaddingBottom = UDim.new(0, 12),
	}, page)
	local tab = { Name = name, Page = page, Button = btn, Bar = bar, Label = lbl }
	onAccent(function(c)
		bar.BackgroundColor3 = c
		page.ScrollBarImageColor3 = c
	end)
	connect(btn.MouseButton1Click, function()
		selectTab(tab)
	end)
	table.insert(tabs, tab)
	return page, tab
end

local function newRow(page, height)
	local r = new("Frame", {
		Size = UDim2.new(1, 0, 0, height or 36),
		BackgroundColor3 = Theme.Panel2,
		BorderSizePixel = 0,
		LayoutOrder = nextOrder(page),
	}, page)
	corner(r, 8)
	return r
end

local function rowLabel(parent, text, widthOffset)
	return new("TextLabel", {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -(widthOffset or 70), 1, 0),
		BackgroundTransparency = 1,
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Theme.Text,
	}, parent)
end

local function addSection(page, text)
	local l = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Text = string.upper(text),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		LayoutOrder = nextOrder(page),
	}, page)
	onAccent(function(c)
		l.TextColor3 = c
	end)
end

local function addNote(page, text)
	return new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.Muted,
		LayoutOrder = nextOrder(page),
	}, page)
end

-- key capture button. onFire runs when the bound key is pressed (nil = capture only).
local function makeKeyButton(parent, position, size, id, onChange, onFire)
	local btn = new("TextButton", {
		Position = position,
		Size = size,
		BackgroundColor3 = Theme.Panel,
		Text = "",
		AutoButtonColor = false,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = Theme.Muted,
		BorderSizePixel = 0,
	}, parent)
	corner(btn, 6)
	local obj = { Key = nil, fire = onFire }
	local function refresh()
		if listening == obj then
			btn.Text = "..."
		else
			btn.Text = obj.Key and obj.Key.Name or "None"
		end
	end
	obj.refresh = refresh
	function obj.set(k)
		obj.Key = k
		refresh()
		if onChange then
			onChange(k)
		end
	end
	connect(btn.MouseButton1Click, function()
		local prev = listening
		listening = obj
		if prev and prev ~= obj then
			prev.refresh()
		end
		refresh()
	end)
	table.insert(keybinds, obj)
	register(id, function()
		return obj.Key and obj.Key.Name or nil
	end, function(name)
		local key = nil
		if type(name) == "string" then
			local ok, k = pcall(function()
				return Enum.KeyCode[name]
			end)
			if ok then
				key = k
			end
		end
		obj.set(key)
	end)
	refresh()
	return obj
end

-- o: Id, Name, Default, Bind (bool), Callback(v)
local function addToggle(page, o)
	local r = newRow(page)
	rowLabel(r, o.Name, o.Bind and 160 or 70)
	local value = false
	local track = new("Frame", {
		Size = UDim2.fromOffset(40, 20),
		Position = UDim2.new(1, -52, 0.5, -10),
		BackgroundColor3 = Theme.Off,
		BorderSizePixel = 0,
	}, r)
	corner(track, 10)
	local knob = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, track)
	corner(knob, 7)
	local hit = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "" }, r)

	local obj = {}
	function obj.set(v)
		value = v and true or false
		TweenService:Create(track, TweenInfo.new(0.15), { BackgroundColor3 = value and Theme.Accent or Theme.Off }):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), { Position = value and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3) }):Play()
		if o.Callback then
			o.Callback(value)
		end
	end
	function obj.get()
		return value
	end
	onAccent(function(c)
		if value then
			track.BackgroundColor3 = c
		end
	end)
	connect(hit.MouseButton1Click, function()
		obj.set(not value)
	end)
	register(o.Id, obj.get, function(v)
		obj.set(v)
	end)
	if o.Bind then
		obj.key = makeKeyButton(r, UDim2.new(1, -142, 0.5, -11), UDim2.fromOffset(80, 22), o.Id and (o.Id .. "_key"), nil, function()
			obj.set(not value)
			notify(o.Name .. (value and ": ON" or ": OFF"))
		end)
	end
	obj.set(o.Default or false)
	return obj
end

-- o: Id, Name, Default (KeyCode), Callback(key), Fire()
local function addKeybindRow(page, o)
	local r = newRow(page)
	rowLabel(r, o.Name, 110)
	local kb = makeKeyButton(r, UDim2.new(1, -94, 0.5, -11), UDim2.fromOffset(82, 22), o.Id, o.Callback, o.Fire)
	if o.Default then
		kb.set(o.Default)
	end
	return kb
end

-- o: Id, Name, Min, Max, Step, Default, Decimals, Suffix, Callback(v)
local function addSlider(page, o)
	local r = newRow(page, 50)
	new("TextLabel", {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -110, 0, 18),
		BackgroundTransparency = 1,
		Text = o.Name,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Theme.Text,
	}, r)
	local valueLabel = new("TextLabel", {
		Position = UDim2.new(1, -98, 0, 6),
		Size = UDim2.fromOffset(86, 18),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = Theme.Muted,
	}, r)
	local bar = new("Frame", {
		Position = UDim2.fromOffset(12, 33),
		Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
	}, r)
	corner(bar, 3)
	local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BorderSizePixel = 0 }, bar)
	corner(fill, 3)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, bar)
	corner(knob, 6)
	onAccent(function(c)
		fill.BackgroundColor3 = c
	end)
	local hit = new("TextButton", {
		Position = UDim2.fromOffset(8, 24),
		Size = UDim2.new(1, -16, 0, 24),
		BackgroundTransparency = 1,
		Text = "",
	}, r)

	local obj = {}
	local value = o.Min
	function obj.set(v)
		if type(v) ~= "number" or v ~= v then
			return
		end
		v = math.clamp(v, o.Min, o.Max)
		value = v
		local a = (v - o.Min) / (o.Max - o.Min)
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
		valueLabel.Text = string.format("%." .. (o.Decimals or 0) .. "f%s", v, o.Suffix or "")
		if o.Callback then
			o.Callback(v)
		end
	end
	function obj.get()
		return value
	end
	function obj.update(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local raw = o.Min + a * (o.Max - o.Min)
		obj.set(math.floor(raw / o.Step + 0.5) * o.Step)
	end
	connect(hit.InputBegan, function(i)
		if isPointer(i) then
			activeSlider = obj
			obj.update(i.Position.X)
		end
	end)
	register(o.Id, obj.get, obj.set)
	obj.set(o.Default or o.Min)
	return obj
end

-- o: Id, Name, Options {strings}, Default, Callback(v)
local function addSelector(page, o)
	local r = newRow(page)
	rowLabel(r, o.Name, 140)
	local btn = new("TextButton", {
		Position = UDim2.new(1, -122, 0.5, -11),
		Size = UDim2.fromOffset(110, 22),
		BackgroundColor3 = Theme.Panel,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = Theme.Text,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
	}, r)
	corner(btn, 6)
	local obj = {}
	local value = o.Options[1]
	function obj.set(v)
		if table.find(o.Options, v) == nil then
			return
		end
		value = v
		btn.Text = v
		if o.Callback then
			o.Callback(v)
		end
	end
	function obj.get()
		return value
	end
	connect(btn.MouseButton1Click, function()
		local idx = table.find(o.Options, value) or 0
		obj.set(o.Options[idx % #o.Options + 1])
	end)
	register(o.Id, obj.get, obj.set)
	obj.set(o.Default or o.Options[1])
	return obj
end

local function addButton(page, o)
	local btn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = Theme.Panel2,
		Text = o.Name,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = Theme.Text,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		LayoutOrder = nextOrder(page),
	}, page)
	corner(btn, 8)
	connect(btn.MouseEnter, function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = Theme.Panel2:Lerp(Theme.Accent, 0.35) }):Play()
	end)
	connect(btn.MouseLeave, function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = Theme.Panel2 }):Play()
	end)
	connect(btn.MouseButton1Click, o.Callback)
end

local function addSwatches(page)
	local r = new("Frame", {
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = Theme.Panel2,
		BorderSizePixel = 0,
		LayoutOrder = nextOrder(page),
	}, page)
	corner(r, 8)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, r)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12) }, r)
	local swatches = {}
	for i, p in AccentPresets do
		local b = new("TextButton", {
			Size = UDim2.fromOffset(28, 28),
			BackgroundColor3 = p.Color,
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			LayoutOrder = i,
		}, r)
		corner(b, 14)
		local st = new("UIStroke", { Thickness = 2, Color = Color3.new(1, 1, 1), Enabled = false }, b)
		connect(b.MouseButton1Click, function()
			setAccent(p.Color)
		end)
		table.insert(swatches, { stroke = st, color = p.Color })
	end
	onAccent(function(c)
		for _, s in swatches do
			s.stroke.Enabled = s.color == c
		end
	end)
	register("accent", function()
		local c = Theme.Accent
		return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
	end, function(v)
		if type(v) == "table" and #v == 3 then
			setAccent(Color3.fromRGB(v[1], v[2], v[3]))
		end
	end)
end

---------------------------------------------------------------------
-- CONFIG FILE
---------------------------------------------------------------------
local DIR = "Meriada"
local FILE = DIR .. "/config.json"

local function saveConfig()
	if not writefile then
		return false, "writefile is not available in this executor"
	end
	local data = {}
	for id, e in Registry do
		data[id] = e.get()
	end
	return pcall(function()
		if makefolder and isfolder and not isfolder(DIR) then
			makefolder(DIR)
		end
		writefile(FILE, HttpService:JSONEncode(data))
	end)
end

local function loadConfig()
	if not (isfile and readfile) then
		return false, "readfile/isfile are not available in this executor"
	end
	if not isfile(FILE) then
		return false, "no saved config yet"
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(FILE))
	end)
	if not ok or type(data) ~= "table" then
		return false, "config file is unreadable"
	end
	for id, v in data do
		local e = Registry[id]
		if e then
			pcall(e.set, v)
		end
	end
	return true
end

---------------------------------------------------------------------
-- TAB: COMBAT
---------------------------------------------------------------------
local combat = addTab("Combat")
addSection(combat, "Auto Block")
addNote(combat, "Holds block while a mapped attack animation (Kind = \"block\") is playing. Click the key box to bind a hotkey; Esc clears it.")
addToggle(combat, {
	Id = "autoBlock", Name = "Auto Block", Bind = true,
	Callback = function(v) State.AutoBlock = v end,
})
addSelector(combat, {
	Id = "trigger", Name = "Trigger", Options = { "any", "list" }, Default = Config.Trigger,
	Callback = function(v) Config.Trigger = v end,
})
addSlider(combat, {
	Id = "anyDelay", Name = "Reaction delay (any mode)", Min = 0, Max = 0.5, Step = 0.01, Default = Config.AnyDelay, Decimals = 2, Suffix = " s",
	Callback = function(v) Config.AnyDelay = v end,
})
addSlider(combat, {
	Id = "holdTime", Name = "Block hold time", Min = 0.1, Max = 1.5, Step = 0.05, Default = Config.HoldTime, Decimals = 2, Suffix = " s",
	Callback = function(v) Config.HoldTime = v end,
})
addToggle(combat, {
	Id = "reactive", Name = "Block when I take damage", Default = Config.Reactive,
	Callback = function(v) Config.Reactive = v end,
})
addSlider(combat, {
	Id = "reactiveRange", Name = "Damage reaction range", Min = 3, Max = 30, Step = 1, Default = Config.ReactiveRange, Suffix = " studs",
	Callback = function(v) Config.ReactiveRange = v end,
})
addSection(combat, "Auto Parry")
addNote(combat, "Taps block at the mapped moment of an attack (Kind = \"parry\"). Timing comes from Delay in the Attacks table.")
addToggle(combat, {
	Id = "autoParry", Name = "Auto Parry", Bind = true,
	Callback = function(v) State.AutoParry = v end,
})
addSection(combat, "Status")
local statusLabel = addNote(combat, "")
addSection(combat, "Tools")
addButton(combat, {
	Name = "Test block (presses the block key now)",
	Callback = function()
		if busy then
			notify("Test: a block is already active")
			return
		end
		if not blockConfigured() then
			notify("Test: block input is not configured")
			return
		end
		notify(("Test: holding block for %.2f s"):format(Config.HoldTime))
		task.spawn(execute, { Kind = "block" }, nil)
	end,
})
addToggle(combat, {
	Id = "learn", Name = "Learn mode (log animations)", Default = Config.Learn,
	Callback = function(v) Config.Learn = v end,
})

refreshStatus = function()
	local b, p = 0, 0
	for _, e in Config.Attacks do
		if e.Kind == "block" then
			b += 1
		elseif e.Kind == "parry" then
			p += 1
		end
	end
	statusLabel.Text = ("Block input: %s\nTrigger: %s    Damage reaction: %s\nAttacks mapped: %d block, %d parry\nAuto Block: %s    Auto Parry: %s"):format(
		blockConfigured() and "configured" or "NOT configured (Settings > Block input)",
		Config.Trigger, Config.Reactive and "on" or "off",
		b, p, State.AutoBlock and "ON" or "OFF", State.AutoParry and "ON" or "OFF")
end
refreshStatus()

---------------------------------------------------------------------
-- TAB: SETTINGS
---------------------------------------------------------------------
local settings = addTab("Settings")
addSection(settings, "Interface")
addKeybindRow(settings, {
	Id = "menuKey", Name = "Menu key", Default = Enum.KeyCode.RightShift,
	Fire = function() setMenuVisible(not main.Visible) end,
})
addButton(settings, {
	Name = "Save config",
	Callback = function()
		local ok, err = saveConfig()
		notify(ok and "Config saved" or ("Save failed: " .. tostring(err)))
	end,
})
addButton(settings, {
	Name = "Load config",
	Callback = function()
		local ok, err = loadConfig()
		notify(ok and "Config loaded" or ("Load failed: " .. tostring(err)))
	end,
})
addButton(settings, { Name = "Unload Meriada", Callback = function() Unload() end })

addSection(settings, "Block input")
addSelector(settings, {
	Id = "blockMode", Name = "Mode", Options = { "unset", "key", "remote" }, Default = Config.Block.Mode or "unset",
	Callback = function(v) Config.Block.Mode = (v ~= "unset") and v or nil end,
})
addSelector(settings, {
	Id = "inputMethod", Name = "Key input method", Options = { "both", "vim", "keypress" }, Default = Config.InputMethod,
	Callback = function(v) Config.InputMethod = v end,
})
addKeybindRow(settings, {
	Id = "blockKey", Name = "In-game block key (key mode)", Default = Config.Block.Key,
	Callback = function(k) Config.Block.Key = k end,
})
addNote(settings, "Remote mode needs Config.Block.Remote and Config.Block.BuildArgs filled in at the top of Meriada.lua (find them with RemoteSpy.lua). Do not bind a menu hotkey to the same key as the in-game block key.")

addSection(settings, "Detection")
addSelector(settings, {
	Id = "detectMode", Name = "Detection mode", Options = { "event", "poll" }, Default = Config.DetectMode,
	Callback = function(v) Config.DetectMode = v end,
})
addSelector(settings, {
	Id = "anyPriority", Name = "Any mode: min priority", Options = { "Idle", "Movement", "Action", "Action2", "Action3", "Action4" }, Default = Config.AnyMinPriority,
	Callback = function(v) Config.AnyMinPriority = v end,
})
addSlider(settings, {
	Id = "maxDistance", Name = "Max distance", Min = 1, Max = 30, Step = 0.5, Default = Config.MaxDistance, Decimals = 1, Suffix = " studs",
	Callback = function(v) Config.MaxDistance = v end,
})
addToggle(settings, {
	Id = "facingCheck", Name = "Attacker must face me", Default = Config.FacingCheck,
	Callback = function(v) Config.FacingCheck = v end,
})
addSlider(settings, {
	Id = "facingDot", Name = "Facing threshold", Min = 0, Max = 1, Step = 0.05, Default = Config.FacingDot, Decimals = 2,
	Callback = function(v) Config.FacingDot = v end,
})
addToggle(settings, {
	Id = "pingComp", Name = "Ping compensation", Default = Config.CompensatePing,
	Callback = function(v) Config.CompensatePing = v end,
})
addSlider(settings, {
	Id = "tapTime", Name = "Parry tap time", Min = 0.02, Max = 0.3, Step = 0.01, Default = Config.TapTime, Decimals = 2, Suffix = " s",
	Callback = function(v) Config.TapTime = v end,
})
addToggle(settings, {
	Id = "includeNpcs", Name = "Include NPCs / dummies", Default = Config.IncludeNpcs,
	Callback = function(v) Config.IncludeNpcs = v end,
})
addToggle(settings, {
	Id = "ignoreTeam", Name = "Ignore teammates", Default = Config.IgnoreTeammates,
	Callback = function(v) Config.IgnoreTeammates = v end,
})

---------------------------------------------------------------------
-- TAB: THEME
---------------------------------------------------------------------
local themeTab = addTab("Theme")
addSection(themeTab, "Accent color")
addSwatches(themeTab)
addSection(themeTab, "Title")
addToggle(themeTab, {
	Id = "animTitle", Name = "Animated Meriada title", Default = true,
	Callback = function(v) Theme.AnimateTitle = v end,
})
addSection(themeTab, "Window")
addSlider(themeTab, {
	Id = "winTransp", Name = "Window transparency", Min = 0, Max = 0.5, Step = 0.01, Default = 0, Decimals = 2,
	Callback = function(v) main.BackgroundTransparency = v end,
})

selectTab(tabs[1])

---------------------------------------------------------------------
-- LIFECYCLE
---------------------------------------------------------------------
Unload = function()
	Alive = false
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	clearReactive()
	for player in charConns do
		clearChar(player)
	end
	if pressed then
		local release = pressed
		pressed = nil
		release()
	end
	if gui then
		gui:Destroy()
	end
	env.__MeriadaUnload = nil
	print("[Meriada] unloaded")
end
env.__MeriadaUnload = Unload

do
	local ok = loadConfig() -- silently applies a previous save if one exists
	if ok then
		notify("Config loaded")
	end
end

print(("[Meriada] loaded. block input configured: %s | VIM: %s, keypress: %s | menu key: RightShift (changeable in Settings)"):format(
	tostring(blockConfigured()), tostring(VIM ~= nil), tostring(keypress ~= nil and keyrelease ~= nil)))
