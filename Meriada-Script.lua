--[[
    ============================================================================
    REVENGERS X — MODULAR COMBAT SUITE (Auto Block 5-Hit, Post-Hit Recovery, Parry)
    Language: Luau (Roblox Client Executor Compatible)
    Sections:
      [SEC 1] Config & Runtime State
      [SEC 2] Safe Executor Wrappers, Services & Input Manager (Anti-Stuck)
      [SEC 3] Combat Core (5-Hit Combo Hold, Post-Hit Recovery, Auto Parry, Learn Mode)
      [SEC 4] Custom Dark UI Library (Tween Open/Close, Drag, Toasts, Theme Engine)
      [SEC 5] UI Tabs (Combat, Settings, Theme) & Lifecycle / Safe Unload
    ============================================================================
]]

-- Prevent duplicate instances; cleanly unload previous instance if re-executed
if getgenv and getgenv().__RevengersX_Unload then
    pcall(getgenv().__RevengersX_Unload)
end

-- ============================================================================
-- [SEC 1] CONFIG & RUNTIME STATE
-- ============================================================================
local Config = {
    Combat = {
        AutoBlock = true,
        PostHitRecovery = true,
        AutoDodge = true,
        DodgeFallbackToBlock = true,

        -- Timing parameters tuned for 4-5 hit fighting combos
        BlockLeadTime = 0.14,         -- Seconds before impact to press Block
        ComboHoldExtension = 0.38,    -- Extra hold window between M1 combo hits (prevents dropping block mid-string)
        PostHitWindow = 0.45,         -- Window after stun/hit where recovery immediately re-raises block
        MinBlockDuration = 0.22,      -- Minimum hold time once block starts

        DodgeLeadTime = 0.11,         -- Seconds before impact to tap Dodge/Parry
        DodgeCooldown = 1.60,         -- Cooldown of Q dodge
        DodgeTapDuration = 0.05,      -- Key hold duration for dodge tap

        -- Threat filtering
        MaxDistance = 16.5,           -- Studs
        FacingCheck = true,
        FacingDotThreshold = 0.35,    -- LookVector dot product threshold (-1 to 1)
        PingMultiplier = 1.00,        -- Scales network ping compensation
        IgnoreTeamAndDead = true,
        FilterMode = "AllCombat",     -- "AllCombat" | "WhitelistOnly"
        LearnMode = false,
    },
    Settings = {
        InputMode = "Auto",           -- "Key" | "Remote" | "Auto"
        KeyMethod = "VIM",            -- "VIM" | "keypress" | "Both"
        BlockKey = "F",
        DodgeKey = "Q",
        MenuKey = "RightShift",
        MaxKeyHoldWatchdog = 2.60,    -- Anti-stuck safety release timeout
        ConfigFolder = "RevengersX_Config",
        ConfigFile = "RevengersX_Config/settings.json",
    },
    Theme = {
        AccentHEX = "#7C3AED",
        AccentR = 124,
        AccentG = 58,
        AccentB = 237,
        AnimatedHeader = true,
        WindowTransparency = 0.06,
    },
    -- Known attack animations & dynamically learned hit timings: [animId] = hitFraction (0.0 - 1.0)
    AttackWhitelist = {
        -- Can be populated or learned via Learn Mode
    },
    LearnedTimings = {}
}

local State = {
    Unloaded = false,
    MenuOpen = true,
    IsBlocking = false,
    BlockStartTimestamp = 0,
    BlockReleaseTimestamp = 0,
    LastDodgeTimestamp = 0,
    IsDodging = false,

    -- Combo & Post-Hit tracking
    ActiveComboCount = 0,
    LastEnemySwingTimestamp = 0,
    LastDamageTakenTimestamp = 0,
    LastHealth = nil,
    WasInHitstun = false,

    -- Active connections & tracked animations
    Connections = {},
    TrackedTracks = {}, -- [AnimationTrack] = metadata
    BindingTarget = nil,
}

-- ============================================================================
-- [SEC 2] SAFE EXECUTOR WRAPPERS, SERVICES & INPUT MANAGER
-- ============================================================================
local function SafeGetService(serviceName)
    local ok, svc = pcall(function()
        local s = game:GetService(serviceName)
        if cloneref then
            return cloneref(s)
        end
        return s
    end)
    return ok and svc or nil
end

local Players = SafeGetService("Players")
local RunService = SafeGetService("RunService")
local UserInputService = SafeGetService("UserInputService")
local TweenService = SafeGetService("TweenService")
local HttpService = SafeGetService("HttpService")
local Stats = SafeGetService("Stats")
local CoreGui = SafeGetService("CoreGui")
local VirtualInputManager = SafeGetService("VirtualInputManager")

local LocalPlayer = Players and Players.LocalPlayer

local function TrackConnection(conn)
    if conn then
        table.insert(State.Connections, conn)
    end
    return conn
end

-- Safe GUI Parent resolution (gethui -> CoreGui -> PlayerGui)
local function GetSafeGuiParent()
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    if CoreGui then
        local ok, _ = pcall(function() return CoreGui.Name end)
        if ok then return CoreGui end
    end
    if LocalPlayer then
        return LocalPlayer:FindFirstChildOfClass("PlayerGui")
    end
    return nil
end

-- Virtual KeyCodes lookup for optional keypress/keyrelease executor APIs
local VK_MAP = {
    F = 0x46, Q = 0x51, E = 0x45, R = 0x52, G = 0x47,
    V = 0x56, C = 0x43, X = 0x58, Z = 0x5A, LeftShift = 0x10, RightShift = 0xA1
}

local function GetEnumKeyCode(keyName)
    local ok, code = pcall(function()
        return Enum.KeyCode[keyName]
    end)
    return (ok and code) or Enum.KeyCode.F
end

-- Remote fallback discovery for Revengers X style combat remotes
local CachedCombatRemote = nil
local function TryFireCombatRemote(actionName, stateBool)
    if Config.Settings.InputMode == "Key" then return false end
    pcall(function()
        if not CachedCombatRemote then
            local rep = SafeGetService("ReplicatedStorage")
            if rep then
                for _, desc in ipairs(rep:GetDescendants()) do
                    if desc:IsA("RemoteEvent") then
                        local n = string.lower(desc.Name)
                        if string.find(n, "block") or string.find(n, "combat") or string.find(n, "guard") or string.find(n, "dodge") then
                            CachedCombatRemote = desc
                            break
                        end
                    end
                end
            end
        end
        if CachedCombatRemote then
            CachedCombatRemote:FireServer(actionName, stateBool)
        end
    end)
    return CachedCombatRemote ~= nil
end

-- Low-level Key Press / Release with VIM + keypress support
local HeldKeys = {}

local function SendKeyDown(keyName)
    if State.Unloaded then return end
    HeldKeys[keyName] = os.clock()
    local method = Config.Settings.KeyMethod
    local enumKey = GetEnumKeyCode(keyName)

    if Config.Settings.InputMode ~= "Remote" then
        if (method == "VIM" or method == "Both") and VirtualInputManager then
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, enumKey, false, game)
            end)
        end
        if (method == "keypress" or method == "Both") and type(keypress) == "function" then
            local vk = VK_MAP[keyName]
            if vk then pcall(keypress, vk) end
        end
    end
end

local function SendKeyUp(keyName)
    HeldKeys[keyName] = nil
    local method = Config.Settings.KeyMethod
    local enumKey = GetEnumKeyCode(keyName)

    if (method == "VIM" or method == "Both") and VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, enumKey, false, game)
        end)
    end
    if (method == "keypress" or method == "Both") and type(keyrelease) == "function" then
        local vk = VK_MAP[keyName]
        if vk then pcall(keyrelease, vk) end
    end
end

local function ForceReleaseAllKeys()
    for keyName, _ in pairs(HeldKeys) do
        SendKeyUp(keyName)
    end
    if State.IsBlocking then
        State.IsBlocking = false
        SendKeyUp(Config.Settings.BlockKey)
        TryFireCombatRemote("Block", false)
    end
end

-- Config Save / Load via JSON (executor filesystem safe wrappers)
local function SaveConfigToDisk()
    if type(writefile) ~= "function" or not HttpService then
        return false, "writefile not supported"
    end
    local ok, err = pcall(function()
        if type(isfolder) == "function" and type(makefolder) == "function" then
            if not isfolder(Config.Settings.ConfigFolder) then
                makefolder(Config.Settings.ConfigFolder)
            end
        end
        local json = HttpService:JSONEncode(Config)
        writefile(Config.Settings.ConfigFile, json)
    end)
    return ok, err
end

local function LoadConfigFromDisk()
    if type(readfile) ~= "function" or type(isfile) ~= "function" or not HttpService then
        return false, "readfile/isfile not supported"
    end
    local ok, err = pcall(function()
        if not isfile(Config.Settings.ConfigFile) then
            error("Config file does not exist yet")
        end
        local raw = readfile(Config.Settings.ConfigFile)
        local decoded = HttpService:JSONDecode(raw)
        if type(decoded) == "table" then
            for section, values in pairs(decoded) do
                if type(Config[section]) == "table" and type(values) == "table" then
                    for k, v in pairs(values) do
                        Config[section][k] = v
                    end
                end
            end
        end
    end)
    return ok, err
end

-- ============================================================================
-- [SEC 3] COMBAT CORE (AUTO BLOCK 5-HIT, POST-HIT RECOVERY, PARRY, LEARN MODE)
-- ============================================================================
local NotifyToast -- Forward declaration from UI Library

local function GetPingSeconds()
    local pingSec = 0.065
    pcall(function()
        if Stats and Stats.Network and Stats.Network.ServerStatsItem then
            local dataPing = Stats.Network.ServerStatsItem["Data Ping"]
            if dataPing then
                pingSec = math.clamp(dataPing:GetValue() / 1000, 0.015, 0.350)
            end
        end
    end)
    return pingSec * Config.Combat.PingMultiplier
end

local function GetCharacterParts(plrOrModel)
    local char = plrOrModel
    if plrOrModel and plrOrModel:IsA("Player") then
        char = plrOrModel.Character
    end
    if not char then return nil, nil, nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    return char, hrp, hum
end

-- Check if local player is currently stunned / in hit-recovery
local function IsLocalPlayerInHitstun(char, hum)
    if not char or not hum then return false end
    if hum.PlatformStand or hum.Sit then return true end
    if hum.WalkSpeed <= 4 then return true end

    local stunKeywords = { "Stun", "Hitstun", "Hit", "Ragdoll", "Knocked", "ComboStun", "Stunned" }
    for _, kw in ipairs(stunKeywords) do
        if char:GetAttribute(kw) == true or char:FindFirstChild(kw) then
            return true
        end
    end
    return false
end

-- Check if target is valid hostile fighter
local function IsValidAttacker(model)
    if not model or not LocalPlayer or model == LocalPlayer.Character then
        return false
    end
    local _, hrp, hum = GetCharacterParts(model)
    if not hrp or not hum or hum.Health <= 0 then
        return false
    end
    if Config.Combat.IgnoreTeamAndDead then
        local targetPlr = Players and Players:GetPlayerFromCharacter(model)
        if targetPlr and LocalPlayer.Team and targetPlr.Team == LocalPlayer.Team then
            return false
        end
        if model:GetAttribute("Knocked") == true or model:FindFirstChild("Knocked") then
            return false
        end
    end
    return true
end

-- Normalize AnimationId string to numeric ID or clean asset string
local function CleanAnimId(rawId)
    if not rawId then return "" end
    local digits = string.match(tostring(rawId), "%d+")
    return digits or tostring(rawId)
end

-- Evaluate if an AnimationTrack is an offensive non-looped combat swing
local NonCombatTracks = {
    ["180435571"] = true, ["180435792"] = true, ["125750702"] = true,
    ["180426354"] = true, ["180436148"] = true, ["507766388"] = true,
    ["507766666"] = true, ["507767714"] = true, ["507765000"] = true,
}

local function IsCombatAnimationTrack(track)
    if not track or not track.Animation then return false, "" end
    local animId = CleanAnimId(track.Animation.AnimationId)
    if animId == "" or NonCombatTracks[animId] then return false, animId end

    if Config.Combat.FilterMode == "WhitelistOnly" then
        return (Config.AttackWhitelist[animId] == true or Config.LearnedTimings[animId] ~= nil), animId
    end

    if track.Looped then return false, animId end
    local len = track.Length
    if len <= 0.08 or len > 3.80 then return false, animId end

    local prio = track.Priority
    if prio == Enum.AnimationPriority.Core or prio == Enum.AnimationPriority.Idle or prio == Enum.AnimationPriority.Movement then
        return false, animId
    end
    return true, animId
end

-- Start or extend smart block hold (supports 4-5 hit strings without dropping mid-gap)
local function StartOrExtendBlock(holdDuration, reason)
    if State.Unloaded then return end
    local now = os.clock()
    local duration = math.max(holdDuration or 0.30, Config.Combat.MinBlockDuration)
    local targetRelease = now + duration

    if targetRelease > State.BlockReleaseTimestamp then
        State.BlockReleaseTimestamp = targetRelease
    end

    if not State.IsBlocking then
        State.IsBlocking = true
        State.BlockStartTimestamp = now
        SendKeyDown(Config.Settings.BlockKey)
        TryFireCombatRemote("Block", true)
    end
end

local function StopBlock()
    if State.IsBlocking then
        State.IsBlocking = false
        State.BlockReleaseTimestamp = 0
        SendKeyUp(Config.Settings.BlockKey)
        TryFireCombatRemote("Block", false)
    end
end

-- Execute quick Dodge / Parry tap with automatic fallback to Auto Block if on cooldown
local function TryExecuteDodgeOrFallback(holdFallbackDuration)
    if State.Unloaded then return end
    local now = os.clock()
    local dodgeReady = Config.Combat.AutoDodge
        and not State.IsDodging
        and ((now - State.LastDodgeTimestamp) >= Config.Combat.DodgeCooldown)

    if dodgeReady then
        State.IsDodging = true
        State.LastDodgeTimestamp = now

        if State.IsBlocking then
            StopBlock()
        end

        SendKeyDown(Config.Settings.DodgeKey)
        TryFireCombatRemote("Dodge", true)

        task.delay(Config.Combat.DodgeTapDuration, function()
            SendKeyUp(Config.Settings.DodgeKey)
            TryFireCombatRemote("Dodge", false)
            State.IsDodging = false
        end)
        return "Dodged"
    end

    -- Automatic fallback to Auto Block if Dodge is on cooldown or disabled
    if Config.Combat.AutoBlock and (not Config.Combat.AutoDodge or Config.Combat.DodgeFallbackToBlock) then
        StartOrExtendBlock(holdFallbackDuration, "DodgeCooldownFallback")
        return "Blocked"
    end
    return "None"
end

-- Core Heartbeat Combat Loop
local function StepCombatCore()
    if State.Unloaded then return end
    local now = os.clock()

    -- 1. Anti-Stuck Key Watchdog & Scheduled Block Release
    for keyName, pressTime in pairs(HeldKeys) do
        if (now - pressTime) > Config.Settings.MaxKeyHoldWatchdog then
            SendKeyUp(keyName)
        end
    end

    if State.IsBlocking and now >= State.BlockReleaseTimestamp then
        StopBlock()
    end

    local myChar, myHRP, myHum = GetCharacterParts(LocalPlayer)
    if not myChar or not myHRP or not myHum or myHum.Health <= 0 then
        if State.IsBlocking then StopBlock() end
        return
    end

    -- 2. Track HP changes & Hitstun state for Post-Hit Recovery
    if State.LastHealth and myHum.Health < State.LastHealth then
        State.LastDamageTakenTimestamp = now
        -- Learn Mode: record exact animation fraction at the moment damage landed
        if Config.Combat.LearnMode then
            for track, meta in pairs(State.TrackedTracks) do
                if track.IsPlaying and meta.Distance and meta.Distance <= Config.Combat.MaxDistance then
                    local frac = math.clamp(track.TimePosition / math.max(track.Length, 0.01), 0.10, 0.90)
                    Config.LearnedTimings[meta.AnimId] = frac
                    print(string.format(
                        "[RevengersX Learn] HIT CONFIRMED | ID: %s | HitFrac: %.2f | Speed: %.2f | Dist: %.1f",
                        meta.AnimId, frac, track.Speed, meta.Distance
                    ))
                end
            end
        end
    end
    State.LastHealth = myHum.Health

    local currentlyInStun = IsLocalPlayerInHitstun(myChar, myHum)
    local justRecoveredFromStun = State.WasInHitstun and not currentlyInStun
    State.WasInHitstun = currentlyInStun

    -- Reset combo counter if enemy stopped swinging for > 1.15s
    if (now - State.LastEnemySwingTimestamp) > 1.15 then
        State.ActiveComboCount = 0
    end

    -- 3. Scan nearby fighters and their playing AnimationTracks
    local pingSec = GetPingSeconds()
    local threatDetectedClose = false
    local longestComboHoldNeeded = 0

    local candidates = {}
    if Players then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then
                table.insert(candidates, plr.Character)
            end
        end
    end
    -- Also inspect Workspace NPC/Dummy fighters
    local ws = SafeGetService("Workspace")
    if ws then
        for _, child in ipairs(ws:GetChildren()) do
            if child:IsA("Model") and child ~= myChar and not Players:GetPlayerFromCharacter(child) then
                if child:FindFirstChildOfClass("Humanoid") then
                    table.insert(candidates, child)
                end
            end
        end
    end

    for _, enemyModel in ipairs(candidates) do
        if IsValidAttacker(enemyModel) then
            local _, enemyHRP, enemyHum = GetCharacterParts(enemyModel)
            local dist = (myHRP.Position - enemyHRP.Position).Magnitude

            if dist <= Config.Combat.MaxDistance then
                -- Facing check: is the attacker looking towards us?
                local dirToMe = (myHRP.Position - enemyHRP.Position).Unit
                local dot = enemyHRP.CFrame.LookVector:Dot(dirToMe)
                local facingPassed = (not Config.Combat.FacingCheck) or (dot >= Config.Combat.FacingDotThreshold)

                if facingPassed then
                    local animator = enemyHum:FindFirstChildOfClass("Animator") or enemyHum
                    local ok, playingTracks = pcall(function()
                        return animator:GetPlayingAnimationTracks()
                    end)

                    if ok and playingTracks then
                        for _, track in ipairs(playingTracks) do
                            local isCombat, animId = IsCombatAnimationTrack(track)
                            if isCombat then
                                local speed = math.max(math.abs(track.Speed), 0.05)
                                local length = math.max(track.Length, 0.10)
                                local hitFraction = Config.LearnedTimings[animId] or 0.42
                                local hitTimePos = length * hitFraction
                                local remainingToImpact = (hitTimePos - track.TimePosition) / speed
                                local remainingTotal = (length - track.TimePosition) / speed

                                -- Register new swing in combo sequence
                                if not State.TrackedTracks[track] then
                                    State.TrackedTracks[track] = {
                                        AnimId = animId,
                                        StartClock = now,
                                        Reacted = false,
                                        Distance = dist,
                                    }
                                    State.LastEnemySwingTimestamp = now
                                    State.ActiveComboCount = math.min(State.ActiveComboCount + 1, 5)

                                    if Config.Combat.LearnMode then
                                        print(string.format(
                                            "[RevengersX Learn] SWING #%d | ID: %s | Len: %.2fs | Speed: %.2f | Prio: %s | Dist: %.1f",
                                            State.ActiveComboCount, animId, length, speed, tostring(track.Priority.Name), dist
                                        ))
                                    end
                                else
                                    State.TrackedTracks[track].Distance = dist
                                    State.LastEnemySwingTimestamp = now
                                end

                                threatDetectedClose = true
                                local meta = State.TrackedTracks[track]

                                -- Calculate hold window accounting for 4-5 hit combo chaining
                                local comboBonus = (State.ActiveComboCount >= 2) and Config.Combat.ComboHoldExtension or 0.18
                                local holdNeeded = math.max(remainingTotal + comboBonus, Config.Combat.MinBlockDuration)
                                if holdNeeded > longestComboHoldNeeded then
                                    longestComboHoldNeeded = holdNeeded
                                end

                                -- Effective reaction lead window (includes Ping + user LeadTime)
                                local blockReactionWindow = Config.Combat.BlockLeadTime + pingSec
                                local dodgeReactionWindow = Config.Combat.DodgeLeadTime + pingSec

                                -- Standard pre-hit reaction
                                if not meta.Reacted and remainingToImpact <= math.max(blockReactionWindow, dodgeReactionWindow) and remainingToImpact >= -0.08 then
                                    meta.Reacted = true
                                    if Config.Combat.AutoDodge then
                                        TryExecuteDodgeOrFallback(holdNeeded)
                                    elseif Config.Combat.AutoBlock then
                                        StartOrExtendBlock(holdNeeded, "PreHit")
                                    end
                                end

                                -- Combo / Post-Hit Recovery Mode:
                                -- If impact window already passed while we were in hitstun/damaged,
                                -- but the enemy attack or 5-hit string is STILL active near us, immediately raise/extend block
                                if Config.Combat.PostHitRecovery and Config.Combat.AutoBlock then
                                    local recentlyHit = (now - State.LastDamageTakenTimestamp) <= Config.Combat.PostHitWindow
                                    local lateInSwing = (remainingToImpact < 0) and (remainingTotal > 0.04)
                                    if (justRecoveredFromStun or recentlyHit or lateInSwing) and not State.IsDodging then
                                        StartOrExtendBlock(holdNeeded, "PostHitRecovery")
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Keep block alive across small inter-hit gaps during an active 4-5 hit combo string
    if State.IsBlocking and threatDetectedClose and State.ActiveComboCount >= 2 then
        StartOrExtendBlock(longestComboHoldNeeded, "ComboBridge")
    end

    -- Cleanup finished AnimationTracks
    for track, _ in pairs(State.TrackedTracks) do
        if not track.IsPlaying then
            State.TrackedTracks[track] = nil
        end
    end
end

-- ============================================================================
-- [SEC 4] CUSTOM DARK UI LIBRARY (TWEEN OPEN/CLOSE, DRAG, TOASTS, THEME)
-- ============================================================================
local UI = {
    ScreenGui = nil,
    MainFrame = nil,
    ToastHolder = nil,
    AccentElements = {}, -- { {Instance, Property} }
    TabPages = {},
    TabButtons = {},
}

local function GetAccentColor3()
    return Color3.fromRGB(Config.Theme.AccentR, Config.Theme.AccentG, Config.Theme.AccentB)
end

local function RegisterAccent(inst, prop)
    table.insert(UI.AccentElements, { Instance = inst, Property = prop })
    pcall(function()
        inst[prop] = GetAccentColor3()
    end)
end

local function ApplyThemeUpdates()
    local col = GetAccentColor3()
    for _, item in ipairs(UI.AccentElements) do
        if item.Instance and item.Instance.Parent then
            pcall(function()
                item.Instance[item.Property] = col
            end)
        end
    end
    if UI.MainFrame then
        UI.MainFrame.BackgroundTransparency = Config.Theme.WindowTransparency
    end
end

local function CreateCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 6)
    c.Parent = parent
    return c
end

local function CreateStroke(parent, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color or Color3.fromRGB(42, 45, 62)
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0
    s.Parent = parent
    return s
end

-- Toast Notification System
NotifyToast = function(message, duration)
    if State.Unloaded or not UI.ToastHolder then return end
    duration = duration or 2.2

    local toast = Instance.new("Frame")
    toast.Size = UDim2.new(1, 0, 0, 32)
    toast.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
    toast.BackgroundTransparency = 1
    toast.BorderSizePixel = 0
    toast.Parent = UI.ToastHolder
    CreateCorner(toast, 6)
    local stroke = CreateStroke(toast, GetAccentColor3(), 1, 0.3)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 3, 1, -8)
    bar.Position = UDim2.new(0, 4, 0, 4)
    bar.BackgroundColor3 = GetAccentColor3()
    bar.BorderSizePixel = 0
    bar.Parent = toast
    CreateCorner(bar, 2)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -18, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(235, 235, 245)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = tostring(message)
    lbl.TextTransparency = 1
    lbl.Parent = toast

    if TweenService then
        TweenService:Create(toast, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 0.08
        }):Play()
        TweenService:Create(lbl, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
    else
        toast.BackgroundTransparency = 0.08
        lbl.TextTransparency = 0
    end

    task.delay(duration, function()
        if not toast or not toast.Parent then return end
        if TweenService then
            local tw = TweenService:Create(toast, TweenInfo.new(0.22), { BackgroundTransparency = 1 })
            TweenService:Create(lbl, TweenInfo.new(0.22), { TextTransparency = 1 }):Play()
            TweenService:Create(stroke, TweenInfo.new(0.22), { Transparency = 1 }):Play()
            tw:Play()
            tw.Completed:Wait()
        end
        if toast and toast.Parent then
            toast:Destroy()
        end
    end)
end

-- Build Main Window
local function CreateMainUI()
    local parent = GetSafeGuiParent()
    if not parent then return end

    local sg = Instance.new("ScreenGui")
    sg.Name = "RevengersX_CombatSuite"
    sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent = parent
    UI.ScreenGui = sg

    -- Toast Container (Top-Right)
    local toastHolder = Instance.new("Frame")
    toastHolder.Name = "ToastHolder"
    toastHolder.Size = UDim2.new(0, 250, 0, 300)
    toastHolder.Position = UDim2.new(1, -266, 0, 16)
    toastHolder.BackgroundTransparency = 1
    toastHolder.Parent = sg
    local toastLayout = Instance.new("UIListLayout")
    toastLayout.Padding = UDim.new(0, 6)
    toastLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    toastLayout.Parent = toastHolder
    UI.ToastHolder = toastHolder

    -- Main Window Frame
    local main = Instance.new("Frame")
    main.Name = "MainWindow"
    main.Size = UDim2.new(0, 510, 0, 440)
    main.Position = UDim2.new(0.5, -255, 0.5, -220)
    main.BackgroundColor3 = Color3.fromRGB(15, 17, 25)
    main.BackgroundTransparency = Config.Theme.WindowTransparency
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    main.Parent = sg
    CreateCorner(main, 10)
    CreateStroke(main, Color3.fromRGB(45, 48, 68), 1, 0)
    UI.MainFrame = main

    -- Top Animated Accent Line
    local topBar = Instance.new("Frame")
    topBar.Size = UDim2.new(1, 0, 0, 3)
    topBar.BorderSizePixel = 0
    topBar.Parent = main
    RegisterAccent(topBar, "BackgroundColor3")

    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 190, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
    })
    grad.Parent = topBar

    -- Header (Draggable)
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 40)
    header.Position = UDim2.new(0, 0, 0, 3)
    header.BackgroundColor3 = Color3.fromRGB(19, 22, 33)
    header.BorderSizePixel = 0
    header.Parent = main

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -120, 1, 0)
    title.Position = UDim2.new(0, 14, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(245, 245, 250)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "REVENGERS X  •  COMBAT SUITE"
    title.Parent = header

    local bindBadge = Instance.new("TextLabel")
    bindBadge.Size = UDim2.new(0, 86, 0, 22)
    bindBadge.Position = UDim2.new(1, -98, 0.5, -11)
    bindBadge.BackgroundColor3 = Color3.fromRGB(26, 29, 44)
    bindBadge.Font = Enum.Font.Code
    bindBadge.TextSize = 11
    bindBadge.TextColor3 = Color3.fromRGB(180, 185, 205)
    bindBadge.Text = "[" .. Config.Settings.MenuKey .. "]"
    bindBadge.Parent = header
    CreateCorner(bindBadge, 5)
    UI.MenuBindLabel = bindBadge

    -- Smooth Dragging Logic on Header
    local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
    TrackConnection(header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end))
    TrackConnection(header.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end))
    TrackConnection(UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))

    -- Animated Header Gradient Shift
    TrackConnection(RunService.RenderStepped:Connect(function(dt)
        if Config.Theme.AnimatedHeader and grad and grad.Parent then
            grad.Offset = Vector2.new(math.sin(os.clock() * 2.0) * 0.35, 0)
        end
    end))

    -- Tab Bar
    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, 0, 0, 34)
    tabBar.Position = UDim2.new(0, 0, 0, 43)
    tabBar.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
    tabBar.BorderSizePixel = 0
    tabBar.Parent = main

    local tabList = Instance.new("UIListLayout")
    tabList.FillDirection = Enum.FillDirection.Horizontal
    tabList.SortOrder = Enum.SortOrder.LayoutOrder
    tabList.Parent = tabBar

    local contentHolder = Instance.new("Frame")
    contentHolder.Size = UDim2.new(1, -20, 1, -88)
    contentHolder.Position = UDim2.new(0, 10, 0, 82)
    contentHolder.BackgroundTransparency = 1
    contentHolder.Parent = main
    UI.ContentHolder = contentHolder
    UI.TabBar = tabBar
end

local function CreateTab(tabName, order)
    local btn = Instance.new("TextButton")
    btn.LayoutOrder = order
    btn.Size = UDim2.new(1 / 3, 0, 1, 0)
    btn.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
    btn.BackgroundTransparency = (order == 1) and 0 or 1
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamSemibold
    btn.TextSize = 12
    btn.TextColor3 = (order == 1) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(150, 155, 175)
    btn.Text = tabName
    btn.Parent = UI.TabBar

    local indicator = Instance.new("Frame")
    indicator.Size = UDim2.new(1, 0, 0, 2)
    indicator.Position = UDim2.new(0, 0, 1, -2)
    indicator.BorderSizePixel = 0
    indicator.Visible = (order == 1)
    indicator.Parent = btn
    RegisterAccent(indicator, "BackgroundColor3")

    local page = Instance.new("ScrollingFrame")
    page.Name = tabName .. "_Page"
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 4
    page.Visible = (order == 1)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.Parent = UI.ContentHolder
    RegisterAccent(page, "ScrollBarImageColor3")

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = page

    UI.TabPages[tabName] = page
    UI.TabButtons[tabName] = { Button = btn, Indicator = indicator }

    btn.MouseButton1Click:Connect(function()
        for name, data in pairs(UI.TabButtons) do
            local active = (name == tabName)
            data.Button.BackgroundTransparency = active and 0 or 1
            data.Button.TextColor3 = active and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(150, 155, 175)
            data.Indicator.Visible = active
            UI.TabPages[name].Visible = active
        end
    end)

    return page
end

-- UI Control Builders (Toggle, Slider, Button, Cycle Selector)
local function AddToggle(parent, labelText, initialValue, callback)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -6, 0, 34)
    row.BackgroundColor3 = Color3.fromRGB(21, 24, 36)
    row.BorderSizePixel = 0
    row.Parent = parent
    CreateCorner(row, 6)
    CreateStroke(row, Color3.fromRGB(36, 40, 56), 1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -64, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(230, 232, 242)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = labelText
    lbl.Parent = row

    local box = Instance.new("TextButton")
    box.Size = UDim2.new(0, 38, 0, 20)
    box.Position = UDim2.new(1, -48, 0.5, -10)
    box.BackgroundColor3 = initialValue and GetAccentColor3() or Color3.fromRGB(40, 44, 62)
    box.Text = ""
    box.Parent = row
    CreateCorner(box, 10)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = initialValue and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = box
    CreateCorner(knob, 7)

    local state = initialValue
    local function SetState(newVal, silent)
        state = newVal
        box.BackgroundColor3 = state and GetAccentColor3() or Color3.fromRGB(40, 44, 62)
        knob.Position = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        if not silent then
            callback(state)
            NotifyToast(labelText .. ": " .. (state and "ON" or "OFF"))
        end
    end

    box.MouseButton1Click:Connect(function()
        SetState(not state, false)
    end)

    return { Set = SetState, Get = function() return state end }
end

local function AddSlider(parent, labelText, minVal, maxVal, defaultVal, decimals, callback)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -6, 0, 46)
    row.BackgroundColor3 = Color3.fromRGB(21, 24, 36)
    row.BorderSizePixel = 0
    row.Parent = parent
    CreateCorner(row, 6)
    CreateStroke(row, Color3.fromRGB(36, 40, 56), 1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.7, 0, 0, 20)
    lbl.Position = UDim2.new(0, 10, 0, 4)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(220, 224, 235)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = labelText
    lbl.Parent = row

    local valLbl = Instance.new("TextLabel")
    valLbl.Size = UDim2.new(0.3, -10, 0, 20)
    valLbl.Position = UDim2.new(0.7, 0, 0, 4)
    valLbl.BackgroundTransparency = 1
    valLbl.Font = Enum.Font.Code
    valLbl.TextSize = 12
    valLbl.TextColor3 = Color3.fromRGB(240, 240, 250)
    valLbl.TextXAlignment = Enum.TextXAlignment.Right
    valLbl.Text = string.format("%." .. decimals .. "f", defaultVal)
    valLbl.Parent = row

    local track = Instance.new("TextButton")
    track.Size = UDim2.new(1, -20, 0, 8)
    track.Position = UDim2.new(0, 10, 0, 30)
    track.BackgroundColor3 = Color3.fromRGB(35, 38, 54)
    track.Text = ""
    track.AutoButtonColor = false
    track.Parent = row
    CreateCorner(track, 4)

    local fill = Instance.new("Frame")
    local initAlpha = math.clamp((defaultVal - minVal) / (maxVal - minVal), 0, 1)
    fill.Size = UDim2.new(initAlpha, 0, 1, 0)
    fill.BorderSizePixel = 0
    fill.Parent = track
    CreateCorner(fill, 4)
    RegisterAccent(fill, "BackgroundColor3")

    local sliding = false
    local function UpdateFromInput(input)
        local relX = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local raw = minVal + (maxVal - minVal) * relX
        local mult = 10 ^ decimals
        local rounded = math.floor(raw * mult + 0.5) / mult
        fill.Size = UDim2.new(relX, 0, 1, 0)
        valLbl.Text = string.format("%." .. decimals .. "f", rounded)
        callback(rounded)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            UpdateFromInput(input)
        end
    end)
    TrackConnection(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
        end
    end))
    TrackConnection(UserInputService.InputChanged:Connect(function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            UpdateFromInput(input)
        end
    end))
end

local function AddButton(parent, text, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -6, 0, 32)
    btn.BackgroundColor3 = Color3.fromRGB(27, 31, 46)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamSemibold
    btn.TextSize = 12
    btn.TextColor3 = Color3.fromRGB(240, 240, 250)
    btn.Text = text
    btn.Parent = parent
    CreateCorner(btn, 6)
    CreateStroke(btn, Color3.fromRGB(48, 53, 74), 1, 0)

    btn.MouseButton1Click:Connect(function()
        callback(btn)
    end)
    return btn
end

local function AddCycleSelector(parent, labelText, options, currentVal, callback)
    local idx = table.find(options, currentVal) or 1
    local btn
    btn = AddButton(parent, labelText .. ":  " .. tostring(options[idx]), function()
        idx = (idx % #options) + 1
        local chosen = options[idx]
        btn.Text = labelText .. ":  " .. tostring(chosen)
        callback(chosen)
        NotifyToast(labelText .. " -> " .. tostring(chosen))
    end)
    return btn
end

-- Toggle Window Open / Close with smooth Tween
local function SetMenuOpen(openState)
    State.MenuOpen = openState
    if not UI.MainFrame then return end
    if openState then
        UI.MainFrame.Visible = true
        if TweenService then
            TweenService:Create(UI.MainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = Config.Theme.WindowTransparency
            }):Play()
        end
    else
        UI.MainFrame.Visible = false
    end
end

-- ============================================================================
-- [SEC 5] TABS CONSTRUCTION (COMBAT, SETTINGS, THEME) & SAFE UNLOAD
-- ============================================================================
CreateMainUI()

local CombatPage = CreateTab("COMBAT", 1)
local SettingsPage = CreateTab("SETTINGS", 2)
local ThemePage = CreateTab("THEME", 3)

-- [1] Populate COMBAT Tab
local AutoBlockToggle = AddToggle(CombatPage, "Auto Block (Smart 5-Hit Combo Hold)", Config.Combat.AutoBlock, function(v)
    Config.Combat.AutoBlock = v
    if not v then StopBlock() end
end)

AddToggle(CombatPage, "Combo / Post-Hit Recovery Mode", Config.Combat.PostHitRecovery, function(v)
    Config.Combat.PostHitRecovery = v
end)

local AutoDodgeToggle = AddToggle(CombatPage, "Auto Parry / Dodge (Q)", Config.Combat.AutoDodge, function(v)
    Config.Combat.AutoDodge = v
end)

AddToggle(CombatPage, "Fallback на Auto Block, если Dodge на КД", Config.Combat.DodgeFallbackToBlock, function(v)
    Config.Combat.DodgeFallbackToBlock = v
end)

AddSlider(CombatPage, "Block Pre-Hit Lead (sec)", 0.04, 0.35, Config.Combat.BlockLeadTime, 2, function(v)
    Config.Combat.BlockLeadTime = v
end)

AddSlider(CombatPage, "5-Hit Combo Hold Extension (sec)", 0.15, 0.80, Config.Combat.ComboHoldExtension, 2, function(v)
    Config.Combat.ComboHoldExtension = v
end)

AddSlider(CombatPage, "Dodge Lead Time (sec)", 0.04, 0.30, Config.Combat.DodgeLeadTime, 2, function(v)
    Config.Combat.DodgeLeadTime = v
end)

AddSlider(CombatPage, "Dodge Cooldown (sec)", 0.50, 5.00, Config.Combat.DodgeCooldown, 2, function(v)
    Config.Combat.DodgeCooldown = v
end)

AddSlider(CombatPage, "Dodge Tap Duration (sec)", 0.02, 0.15, Config.Combat.DodgeTapDuration, 2, function(v)
    Config.Combat.DodgeTapDuration = v
end)

AddSlider(CombatPage, "Max Threat Distance (Studs)", 6.0, 35.0, Config.Combat.MaxDistance, 1, function(v)
    Config.Combat.MaxDistance = v
end)

AddToggle(CombatPage, "FacingCheck (проверка взгляда атакующего)", Config.Combat.FacingCheck, function(v)
    Config.Combat.FacingCheck = v
end)

AddSlider(CombatPage, "Facing Dot Threshold", -0.20, 0.90, Config.Combat.FacingDotThreshold, 2, function(v)
    Config.Combat.FacingDotThreshold = v
end)

AddSlider(CombatPage, "Ping Compensation Multiplier", 0.50, 1.60, Config.Combat.PingMultiplier, 2, function(v)
    Config.Combat.PingMultiplier = v
end)

AddCycleSelector(CombatPage, "Animation Filter", { "AllCombat", "WhitelistOnly" }, Config.Combat.FilterMode, function(mode)
    Config.Combat.FilterMode = mode
end)

AddToggle(CombatPage, "Ignore Teammates & Knocked Targets", Config.Combat.IgnoreTeamAndDead, function(v)
    Config.Combat.IgnoreTeamAndDead = v
end)

AddToggle(CombatPage, "Learn Mode (Лог анимаций и таймингов в F9)", Config.Combat.LearnMode, function(v)
    Config.Combat.LearnMode = v
end)

AddButton(CombatPage, "Тест Блока (Удержание 0.45s)", function()
    StartOrExtendBlock(0.45, "ManualTest")
    NotifyToast("Test Block triggered (0.45s)")
end)

AddButton(CombatPage, "Тест Доджа / Парирования", function()
    local res = TryExecuteDodgeOrFallback(0.35)
    NotifyToast("Test Dodge result: " .. tostring(res))
end)

AddButton(CombatPage, "Сбросить изученные тайминги (Reset Learned)", function()
    table.clear(Config.LearnedTimings)
    NotifyToast("Learned timings cleared")
end)

-- [2] Populate SETTINGS Tab
AddCycleSelector(SettingsPage, "Input Mode", { "Auto", "Key", "Remote" }, Config.Settings.InputMode, function(v)
    Config.Settings.InputMode = v
end)

AddCycleSelector(SettingsPage, "Key Send Method", { "VIM", "keypress", "Both" }, Config.Settings.KeyMethod, function(v)
    Config.Settings.KeyMethod = v
end)

local BlockBindBtn
BlockBindBtn = AddButton(SettingsPage, "Бинд Клавиши Блока: [" .. Config.Settings.BlockKey .. "] (Клик для смены)", function()
    State.BindingTarget = "BlockKey"
    BlockBindBtn.Text = "Нажмите любую клавишу..."
end)

local DodgeBindBtn
DodgeBindBtn = AddButton(SettingsPage, "Бинд Клавиши Доджа: [" .. Config.Settings.DodgeKey .. "] (Клик для смены)", function()
    State.BindingTarget = "DodgeKey"
    DodgeBindBtn.Text = "Нажмите любую клавишу..."
end)

local MenuBindBtn
MenuBindBtn = AddButton(SettingsPage, "Горячая клавиша Меню: [" .. Config.Settings.MenuKey .. "] (Клик для смены)", function()
    State.BindingTarget = "MenuKey"
    MenuBindBtn.Text = "Нажмите любую клавишу..."
end)

AddButton(SettingsPage, "Сохранить Конфиг в JSON", function()
    local ok, err = SaveConfigToDisk()
    NotifyToast(ok and "Конфиг сохранён (JSON)" or ("Ошибка сохранения: " .. tostring(err)))
end)

AddButton(SettingsPage, "Загрузить Конфиг из JSON", function()
    local ok, err = LoadConfigFromDisk()
    if ok then
        ApplyThemeUpdates()
        NotifyToast("Конфиг успешно загружен")
    else
        NotifyToast("Ошибка загрузки: " .. tostring(err))
    end
end)

-- Full Safe Unload Procedure
local function UnloadScript()
    if State.Unloaded then return end
    State.Unloaded = true

    ForceReleaseAllKeys()

    for _, conn in ipairs(State.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(State.Connections)
    table.clear(State.TrackedTracks)

    if UI.ScreenGui then
        pcall(function() UI.ScreenGui:Destroy() end)
        UI.ScreenGui = nil
    end

    if getgenv then
        getgenv().__RevengersX_Unload = nil
    end
end

if getgenv then
    getgenv().__RevengersX_Unload = UnloadScript
end

AddButton(SettingsPage, "Полная выгрузка скрипта (UNLOAD)", function()
    UnloadScript()
end)

-- [3] Populate THEME Tab
local Presets = {
    { Name = "Royal Violet", R = 124, G = 58,  B = 237 },
    { Name = "Crimson Rose", R = 225, G = 29,  B = 72  },
    { Name = "Cyber Cyan",   R = 6,   G = 182, B = 212 },
    { Name = "Neon Emerald", R = 16,  G = 185, B = 129 },
    { Name = "Solar Amber",  R = 245, G = 158, B = 11  },
}

for _, preset in ipairs(Presets) do
    AddButton(ThemePage, "Пресет акцента: " .. preset.Name, function()
        Config.Theme.AccentR = preset.R
        Config.Theme.AccentG = preset.G
        Config.Theme.AccentB = preset.B
        ApplyThemeUpdates()
        NotifyToast("Тема: " .. preset.Name)
    end)
end

AddSlider(ThemePage, "Кастомный Акцент — Red (R)", 0, 255, Config.Theme.AccentR, 0, function(v)
    Config.Theme.AccentR = v
    ApplyThemeUpdates()
end)

AddSlider(ThemePage, "Кастомный Акцент — Green (G)", 0, 255, Config.Theme.AccentG, 0, function(v)
    Config.Theme.AccentG = v
    ApplyThemeUpdates()
end)

AddSlider(ThemePage, "Кастомный Акцент — Blue (B)", 0, 255, Config.Theme.AccentB, 0, function(v)
    Config.Theme.AccentB = v
    ApplyThemeUpdates()
end)

AddToggle(ThemePage, "Анимация градиента заголовка", Config.Theme.AnimatedHeader, function(v)
    Config.Theme.AnimatedHeader = v
end)

AddSlider(ThemePage, "Прозрачность окна (Transparency)", 0.00, 0.45, Config.Theme.WindowTransparency, 2, function(v)
    Config.Theme.WindowTransparency = v
    ApplyThemeUpdates()
end)

-- ============================================================================
-- GLOBAL KEYBIND LISTENER & HEARTBEAT CONNECTION
-- ============================================================================
TrackConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.Unloaded then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

    local pressedName = input.KeyCode.Name

    -- Handle interactive keybind assignment
    if State.BindingTarget then
        local target = State.BindingTarget
        State.BindingTarget = nil
        Config.Settings[target] = pressedName

        if target == "BlockKey" then
            BlockBindBtn.Text = "Бинд Клавиши Блока: [" .. pressedName .. "] (Клик для смены)"
        elseif target == "DodgeKey" then
            DodgeBindBtn.Text = "Бинд Клавиши Доджа: [" .. pressedName .. "] (Клик для смены)"
        elseif target == "MenuKey" then
            MenuBindBtn.Text = "Горячая клавиша Меню: [" .. pressedName .. "] (Клик для смены)"
            if UI.MenuBindLabel then
                UI.MenuBindLabel.Text = "[" .. pressedName .. "]"
            end
        end
        NotifyToast("Новый бинд " .. target .. ": " .. pressedName)
        return
    end

    if gameProcessed then return end

    -- Menu Toggle Hotkey (Default: RightShift)
    if pressedName == Config.Settings.MenuKey then
        SetMenuOpen(not State.MenuOpen)
    end
end))

TrackConnection(RunService.Heartbeat:Connect(StepCombatCore))

NotifyToast("Revengers X Loaded (" .. Config.Settings.MenuKey .. " — меню)", 2.8)
