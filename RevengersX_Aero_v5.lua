--[=[
    Revengers X | Aero Combat Toolkit V10 - local animation recorder
    Client-side Luau utility for Roblox executors.

    IMPORTANT LIMITATIONS
    - No Revengers X-specific attack IDs, hit markers, attributes or RemoteEvents were supplied.
    - Impact timing prefers common named keyframes when present, then falls back to an animation-ratio estimate.
    - Learn Mode can correlate local health loss with a recently validated nearby opponent track; it does not dump all opponents' animation IDs.
    - Remote input is supported only through an explicit RemoteAdapter configured below.
    - V10 records AnimationPlayed events from the LOCAL character and prints only those IDs in the self-recorder.
    - Nearby NPC animations are sampled only when the LOCAL player loses health; regular NPC playback is silent.
    - Immediate response mode rechecks an AnimationPlayed track after a short grace period, then guards only nearby candidates facing or moving toward the local character.
    - An animation track alone does not expose its victim/hitbox; facing and movement are directional heuristics. If the game does not replicate the track to this client, client-side detection cannot see it.

    Recommended: use key input first. Configure exact animation timings only after observing the
    game's animations in Learn mode. This file has not been run inside Roblox or an executor here.

    V10 integration notes (adapted patterns; no foreign game IDs/remotes copied):
    - Animation marker observation: https://github.com/Zyn-ic/AnimateService
    - Config UI foundation: https://github.com/Footagesus/WindUI
    - Cooldown utility pattern: https://github.com/merani2/Roblox-Luau-Utilities
    - Combat diagnostics / event separation inspiration: https://github.com/Diogo-S-Oliveira/CombatSystem-Roblox-MVP
]=]

-- Avoid stacking duplicate copies when the executor reruns this file.
pcall(function()
    if type(_G.AERO_REVENGERS_UNLOAD) == "function" then
        _G.AERO_REVENGERS_UNLOAD()
    end
end)

--==============================================================
-- Config / State
--==============================================================

local CONFIG = {
    Version = 10,
    MenuKey = "RightShift",
    BlockKey = "F",
    DodgeKey = "Q",

    AutoBlock = true,
    AutoDodge = false,             -- keep block as the default response; dodge is opt-in
    ResponseMode = "Immediate",   -- guard as soon as a nearby targeted action track starts
    FacingCheck = true,            -- require the attacker to face or move toward the local character
    FacingDot = 0.05,              -- 0.05 ~= an 87 degree forward cone
    IgnoreSameTeam = false,        -- some FFA games assign one shared Roblox Team to all players
    MaxDistance = 34,
    PingCompensation = true,
    PingFactor = 0.50,             -- use half of measured round-trip ping as lead
    ManualPingMs = 80,              -- fallback if Stats ping is unavailable

    BlockLead = 0.22,
    DodgeLead = 0.12,
    DodgeCooldown = 1.10,
    DodgeTapDuration = 0.12,
    BlockHoldAfterImpact = 0.28,
    ComboGap = 0.42,                -- keeps block through short gaps in 4-5 hit strings
    MaxBlockCommit = 1.35,
    LateWindow = 0.16,

    RecoveryEnabled = true,
    RecoveryWindow = 0.70,
    RecoveryBlockHold = 0.38,
    HitstunAttributes = { "Hitstun", "Stunned", "IsStunned" },

    FilterMode = "ThreatCandidate", -- "ThreatCandidate", "NonLooped", "All", or "Whitelist"
    AttackWhitelist = {},           -- add exact AnimationId strings here for Whitelist mode
    ImpactRatio = 0.72,              -- fallback estimated impact point; not a verified game marker
    LearnedTimings = {},             -- optional damage-correlated timing estimates; verify before relying on them
    LearnMode = false,
    RecordSelfAnimations = true, -- log only this client character
    NpcScanRadius = 10,

    InputMode = "Auto",             -- "Auto", "Key", "Remote"
    InputMethod = "VIM",            -- "VIM", "keypress", "both"
    -- Optional, user-supplied adapter. Do NOT guess the game's RemoteEvent path.
    -- Signature: function(actionName, isDown, keyName) -> boolean
    RemoteAdapter = nil,

    WindowTransparency = 0.08,
    Accent = { 220, 231, 255 },
    AnimateHeader = true,

    -- Detection safeguards / diagnostics.
    LearnDistance = 24,
    UseKeyframeMarkers = true,
    EarlyActionGuard = true,
    ZeroLengthFallback = true,
    ZeroLengthHold = 0.24,
    MaxTrackAge = 3.50,
    PriorityFilter = false,
    DebugCombat = true,
    AnimatorPollInterval = 0.05,
    EventConfirmDelay = 0.045,      -- short re-check to discard tracks cancelled immediately (possible feints)
    UseMovementDirection = true,
    MinAttackerSpeed = 2.25,
    VelocityTowardDot = 0.35,
    ThreatGrace = 0.10,
    SensorRefresh = 0.20,
}

local UIRefs -- forward-declared: Combat Core updates the live sensor when the GUI exists.

local State = {
    Unloaded = false,
    Connections = {},
    PlayerConnections = {},
    CharacterConnections = {},
    LocalCharacterConnections = {},
    Threads = {},
    InputWarned = false,
    ActiveTracks = {},
    HeldKeys = {},
    BlockWantedUntil = 0,
    BlockStartAt = 0,
    DodgeUntil = 0,
    LastDodgeAt = -math.huge,
    RecoveryUntil = 0,
    BindingTarget = nil,
    SliderDrag = nil,
    DraggingWindow = false,
    WindowDragStart = nil,
    WindowStartPosition = nil,
    MenuOpen = true,
    CurrentTab = "Combat",
    LastLearnLog = {},
    KnownTracks = setmetatable({}, { __mode = "k" }),
    LastThreatAt = 0,
    LastThreatPlayer = nil,
    WatchedAnimators = {},
    LastAnimatorPoll = 0,
    LastSensorRefresh = 0,
    LastDebug = {},
    DebugEntries = {},
    LastMarker = "none",
    LastMarkerAt = 0,
    StartedAt = os.clock(),
    Diagnostics = {
        AnimatorsBound = 0,
        NpcAnimatorsBound = 0,
        NpcTracksSeen = 0,
        TracksSeen = 0,
        TracksAccepted = 0,
        TracksRejected = 0,
        BlockRequests = 0,
        LastReject = "none",
        LastBlockReason = "none",
        LastBlockAt = 0,
        LastTarget = "none",
        LastDistance = 0,
        LastFacingDot = -1,
        LastVelocityDot = -1,
    },
}

local DEFAULTS = {}
for k, v in pairs(CONFIG) do
    if type(v) == "table" then
        local copy = {}
        for k2, v2 in pairs(v) do copy[k2] = v2 end
        DEFAULTS[k] = copy
    else
        DEFAULTS[k] = v
    end
end

--==============================================================
-- Safe services / executor capability detection
--==============================================================

local function safeService(name)
    local ok, result = pcall(function()
        return game:GetService(name)
    end)
    if ok then return result end
    return nil
end

local Players = safeService("Players")
local RunService = safeService("RunService")
local UserInputService = safeService("UserInputService")
local TweenService = safeService("TweenService")
local HttpService = safeService("HttpService")
local Stats = safeService("Stats")
local CoreGui = safeService("CoreGui")
local VirtualInputManager = safeService("VirtualInputManager")

if not Players or not RunService or not UserInputService then
    warn("[Aero] Required Roblox services are unavailable; script aborted safely.")
    return
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[Aero] LocalPlayer is unavailable; script aborted safely.")
    return
end

local function getExecutorEnvironment()
    local ok, env = pcall(function()
        if type(getgenv) == "function" then
            return getgenv()
        end
        return _G
    end)
    if ok and type(env) == "table" then return env end
    return _G
end

local ENV = getExecutorEnvironment()
local function capability(name)
    local value
    pcall(function() value = ENV[name] end)
    if value == nil then
        pcall(function() value = _G[name] end)
    end
    return value
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return false, nil end
    local ok, result = pcall(fn, ...)
    return ok, result
end

local function trackConnection(connection, bucket)
    if connection then
        table.insert(bucket or State.Connections, connection)
    end
    return connection
end

local function connect(signal, callback, bucket)
    if not signal then return nil end
    local ok, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if ok then return trackConnection(connection, bucket) end
    return nil
end

local function addThread(thread)
    if thread then table.insert(State.Threads, thread) end
    return thread
end

local function notifyWarn(message)
    warn("[Aero] " .. tostring(message))
end

local function debugLog(key, message, interval)
    if not CONFIG.DebugCombat then return end
    local now = os.clock()
    local delay = interval or 1.0
    if now - (State.LastDebug[key] or -math.huge) < delay then return end
    State.LastDebug[key] = now
    local entry = string.format("[%.3f] %s", now - State.StartedAt, tostring(message))
    table.insert(State.DebugEntries, entry)
    if #State.DebugEntries > 80 then table.remove(State.DebugEntries, 1) end
    print("[Aero Debug] " .. tostring(message))
end

--==============================================================
-- Utility / input core
--==============================================================

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- Small keyed cooldown utility adapted from common open-source Luau cooldown patterns.
-- Kept local so Aero does not need an extra ModuleScript or unpinned dependency.
local CooldownGate = {}
CooldownGate.__index = CooldownGate

function CooldownGate.new(duration)
    return setmetatable({ Duration = math.max(0, tonumber(duration) or 0), ReadyAt = 0 }, CooldownGate)
end

function CooldownGate:Remaining(now)
    return math.max(0, self.ReadyAt - (now or os.clock()))
end

function CooldownGate:IsReady(now)
    return self:Remaining(now) <= 0
end

function CooldownGate:Use(now, duration)
    now = now or os.clock()
    if not self:IsReady(now) then return false, self:Remaining(now) end
    if duration ~= nil then self.Duration = math.max(0, tonumber(duration) or self.Duration) end
    self.ReadyAt = now + self.Duration
    return true, 0
end

function CooldownGate:Reset()
    self.ReadyAt = 0
end

local DodgeCooldownGate = CooldownGate.new(CONFIG.DodgeCooldown)

local function getKeyCode(keyName)
    local result
    pcall(function() result = Enum.KeyCode[keyName] end)
    return result
end

local function getKeyValue(keyName)
    local keyCode = getKeyCode(keyName)
    if keyCode then
        local ok, value = pcall(function() return keyCode.Value end)
        if ok then return value end
    end
    return nil
end

local function sendKeyboardInput(keyName, isDown)
    local keyCode = getKeyCode(keyName)
    if not keyCode then return false end

    local method = CONFIG.InputMethod
    local anySuccess = false

    local function useVIM()
        if not VirtualInputManager then return false end
        local ok = pcall(function()
            VirtualInputManager:SendKeyEvent(isDown, keyCode, false, game)
        end)
        return ok
    end

    local function useKeypress()
        local downFn = capability("keypress")
        local upFn = capability("keyrelease")
        local keyValue = getKeyValue(keyName)
        if not keyValue then return false end
        if type(downFn) ~= "function" or type(upFn) ~= "function" then return false end
        if isDown then
            return pcall(downFn, keyValue)
        end
        return pcall(upFn, keyValue)
    end

    if method == "VIM" then
        anySuccess = useVIM()
    elseif method == "keypress" then
        anySuccess = useKeypress()
    elseif method == "both" then
        local vimOk = useVIM()
        local keyOk = useKeypress()
        anySuccess = vimOk or keyOk
    end
    return anySuccess
end

local function sendInput(actionName, keyName, isDown)
    local mode = CONFIG.InputMode
    local adapter = CONFIG.RemoteAdapter

    if mode == "Remote" then
        if type(adapter) ~= "function" then
            return false, "Remote mode requires CONFIG.RemoteAdapter"
        end
        local ok, result = pcall(adapter, actionName, isDown, keyName)
        return ok and result ~= false, ok and nil or "RemoteAdapter failed"
    end

    if mode == "Auto" and type(adapter) == "function" then
        local ok, result = pcall(adapter, actionName, isDown, keyName)
        if ok and result ~= false then return true end
    end

    return sendKeyboardInput(keyName, isDown), nil
end

local function forceReleaseKey(actionName, keyName)
    local sent = false
    local ok = sendInput(actionName, keyName, false)
    sent = ok or sent

    local keyCode = getKeyCode(keyName)
    if VirtualInputManager and keyCode then
        local vimOk = pcall(function() VirtualInputManager:SendKeyEvent(false, keyCode, false, game) end)
        sent = vimOk or sent
    end

    local releaseFn = capability("keyrelease")
    local keyValue = getKeyValue(keyName)
    if type(releaseFn) == "function" and keyValue then
        local keyOk = pcall(releaseFn, keyValue)
        sent = keyOk or sent
    end

    return sent
end

local function setActionHeld(actionName, keyName, isDown)
    if State.Unloaded then return false end
    if isDown then
        if State.HeldKeys[actionName] then return true end
        local ok, reason = sendInput(actionName, keyName, true)
        if ok then
            State.HeldKeys[actionName] = keyName
            State.InputWarned = false
            return true
        end
        if not State.InputWarned then
            notifyWarn(reason or "No supported input method succeeded; check executor permissions and input settings.")
            State.InputWarned = true
        end
        return false
    end

    local heldKey = State.HeldKeys[actionName]
    if not heldKey then return true end
    forceReleaseKey(actionName, heldKey)
    State.HeldKeys[actionName] = nil
    return true
end

local function releaseAllInputs()
    for actionName, keyName in pairs(State.HeldKeys) do
        pcall(function() forceReleaseKey(actionName, keyName) end)
        State.HeldKeys[actionName] = nil
    end
end

local function requestBlock(untilTime, startAt, reason)
    local now = os.clock()
    if State.BlockWantedUntil < now then
        State.BlockStartAt = startAt or now
    elseif startAt and (State.BlockStartAt == 0 or startAt < State.BlockStartAt) then
        State.BlockStartAt = startAt
    end
    State.BlockWantedUntil = math.max(State.BlockWantedUntil, untilTime)
    State.Diagnostics.BlockRequests += 1
    if reason then
        State.Diagnostics.LastBlockReason = tostring(reason)
        State.Diagnostics.LastBlockAt = now
        debugLog("block_" .. tostring(reason), string.format("block requested: %s | hold-until %.2f", tostring(reason), untilTime), 0.8)
    end
end

local function pulseAction(actionName, keyName, duration)
    if State.Unloaded then return false end
    local ok = setActionHeld(actionName, keyName, true)
    if not ok then return false end
    task.delay(duration, function()
        if not State.Unloaded then setActionHeld(actionName, keyName, false) end
    end)
    return true
end

--==============================================================
-- Combat Core
--==============================================================

local function getCharacterParts(player)
    if not player then return nil, nil, nil end
    local character = player.Character
    if not character then return nil, nil, nil end
    local humanoid, root
    pcall(function()
        humanoid = character:FindFirstChildOfClass("Humanoid")
        root = character:FindFirstChild("HumanoidRootPart")
            or character.PrimaryPart
            or character:FindFirstChild("UpperTorso")
            or character:FindFirstChild("Torso")
    end)
    return character, humanoid, root
end

local function getPingSeconds()
    if not CONFIG.PingCompensation then return 0 end
    local pingMs
    if Stats then
        pcall(function()
            local network = Stats.Network
            local serverStats = network and network.ServerStatsItem
            local dataPing = serverStats and serverStats["Data Ping"]
            if dataPing then
                local value = dataPing:GetValue()
                if type(value) == "number" then pingMs = value end
            end
        end)
    end
    if not pingMs or pingMs < 0 or pingMs > 1000 then
        pingMs = CONFIG.ManualPingMs
    end
    return clamp((pingMs / 1000) * CONFIG.PingFactor, 0, 0.30)
end

local function getTargetDistance(attackerRoot)
    local _, _, localRoot = getCharacterParts(LocalPlayer)
    if not localRoot or not attackerRoot then return math.huge end
    local ok, distance = pcall(function()
        return (localRoot.Position - attackerRoot.Position).Magnitude
    end)
    return ok and distance or math.huge
end

local function getAttackDirectionMetrics(attackerRoot, localRoot)
    if not attackerRoot or not localRoot then return false, -1, -1 end
    local toLocal = localRoot.Position - attackerRoot.Position
    local distance = toLocal.Magnitude
    if distance < 0.05 then return true, 1, 1 end
    local direction = toLocal / distance
    local facingDot, velocityDot = -1, -1
    pcall(function()
        facingDot = attackerRoot.CFrame.LookVector:Dot(direction)
    end)
    pcall(function()
        local velocity = attackerRoot.AssemblyLinearVelocity
        local speed = velocity.Magnitude
        if speed >= CONFIG.MinAttackerSpeed then
            velocityDot = velocity.Unit:Dot(direction)
        end
    end)
    local facingToward = facingDot >= CONFIG.FacingDot
    local movingToward = CONFIG.UseMovementDirection and velocityDot >= CONFIG.VelocityTowardDot
    return facingToward or movingToward, facingDot, velocityDot
end

local function isTargetEligible(player, attackerHumanoid, attackerRoot)
    if State.Unloaded or not player or player == LocalPlayer then return false end
    if player.Parent ~= Players then return false end

    local localCharacter, localHumanoid, localRoot = getCharacterParts(LocalPlayer)
    if not localCharacter or not localHumanoid or not localRoot then return false end
    if localHumanoid.Health <= 0 then return false end
    if not attackerHumanoid or attackerHumanoid.Health <= 0 or not attackerRoot then return false end

    if CONFIG.IgnoreSameTeam and player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then
        return false, nil, "same Roblox Team"
    end

    local distance = getTargetDistance(attackerRoot)
    if distance > CONFIG.MaxDistance then return false, distance, "outside MaxDistance" end

    local directed, facingDot, velocityDot = getAttackDirectionMetrics(attackerRoot, localRoot)
    if CONFIG.FacingCheck and not directed then
        return false, distance,
            string.format("not aimed at local player (facing %.2f / velocity %.2f)", facingDot, velocityDot),
            facingDot, velocityDot
    end

    return true, distance, nil, facingDot, velocityDot
end

-- Learning uses proximity/alive/team checks but deliberately does not require the attacker
-- to be facing the local character. The combat trigger still honors FacingCheck.
local function isLearnTargetEligible(player, attackerHumanoid, attackerRoot)
    if State.Unloaded or not player or player == LocalPlayer or player.Parent ~= Players then return false end
    local _, localHumanoid, localRoot = getCharacterParts(LocalPlayer)
    if not localHumanoid or localHumanoid.Health <= 0 or not localRoot then return false end
    if not attackerHumanoid or attackerHumanoid.Health <= 0 or not attackerRoot then return false end
    if CONFIG.IgnoreSameTeam and player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then return false end
    local distance = getTargetDistance(attackerRoot)
    if distance > CONFIG.LearnDistance then return false end
    return true, distance
end

local function isWhitelisted(animationId)
    for _, id in ipairs(CONFIG.AttackWhitelist) do
        if tostring(id) == tostring(animationId) then return true end
    end
    return false
end

local function isRecovering()
    if not CONFIG.RecoveryEnabled then return false end
    if os.clock() <= State.RecoveryUntil then return true end

    local character, humanoid = getCharacterParts(LocalPlayer)
    if not character or not humanoid then return false end

    for _, attributeName in ipairs(CONFIG.HitstunAttributes) do
        local value
        pcall(function() value = humanoid:GetAttribute(attributeName) end)
        if value == nil then
            pcall(function() value = character:GetAttribute(attributeName) end)
        end
        if value == true or (type(value) == "number" and value > 0) then
            return true
        end
    end
    return false
end

local function estimateImpactTime(animationId, length, track)
    local learned = CONFIG.LearnedTimings[tostring(animationId)]
    if type(learned) == "number" and learned > 0 then
        return clamp(learned, 0, length)
    end

    -- Prefer common explicit keyframe names when the game animation exposes them.
    -- These names are probes, not assumed Revengers X markers; all calls are guarded.
    if CONFIG.UseKeyframeMarkers and track then
        for _, markerName in ipairs({ "Hit", "Hit1", "Hit2", "Hit3", "Hit4", "Hit5", "Impact", "Strike", "Damage" }) do
            local ok, markerTime = pcall(function()
                return track:GetTimeOfKeyframe(markerName)
            end)
            if ok and type(markerTime) == "number" and markerTime > 0 and markerTime < length then
                return markerTime
            end
        end
    end

    return clamp(length * CONFIG.ImpactRatio, 0, length)
end

local function isActionPriority(priority)
    if not priority then return false end
    local value
    pcall(function() value = priority.Value end)
    local actionValue
    pcall(function() actionValue = Enum.AnimationPriority.Action.Value end)
    return type(value) == "number" and type(actionValue) == "number" and value >= actionValue
end

local function learnAnimation(record)
    if not CONFIG.LearnMode then return end
    if not record or not record.Player or not record.Track then return end
    if not record.Length or record.Length <= 0 then return end
    if not record.Distance or record.Distance > CONFIG.LearnDistance then return end

    local now = os.clock()
    local id = tostring(record.AnimationId)
    local playerKey = tostring(record.Player.UserId) .. ":" .. id
    if now - (State.LastLearnLog[playerKey] or -math.huge) < 0.75 then return end
    State.LastLearnLog[playerKey] = now

    local estimate = record.ImpactTime or estimateImpactTime(id, record.Length, record.Track)
    -- Logging is observational only. Do not silently treat the estimate as a verified hit timing.

    local elapsed = 0
    pcall(function() elapsed = record.Track.TimePosition end)
    local line = string.format(
        "[Aero Learn] player=%s | id=%s | length=%.3fs | speed=%.2f | priority=%s | distance=%.2f | position=%.3fs | estimated-impact=%.3fs (heuristic)",
        record.Player.Name,
        id,
        record.Length,
        record.Speed,
        tostring(record.Priority),
        record.Distance,
        elapsed,
        estimate
    )
    print(line)
end

local function registerTrack(player, animator, track)
    if State.Unloaded or not track or State.KnownTracks[track] then return end

    local playingNow
    pcall(function() playingNow = track.IsPlaying end)
    if playingNow == false then return end

    local okLooped, looped = pcall(function() return track.Looped end)
    if not okLooped then return end

    local animationId, length, speed, priority
    pcall(function()
        local animation = track.Animation
        animationId = animation and animation.AnimationId or "unknown"
        length = track.Length
        speed = track.Speed
        priority = track.Priority
    end)

    animationId = tostring(animationId or "unknown")
    length = tonumber(length) or 0
    speed = tonumber(speed) or 1
    priority = priority or "Unknown"
    State.Diagnostics.TracksSeen += 1

    local actionTrack = isActionPriority(priority)
    local rejectedByFilter = false
    if CONFIG.FilterMode == "NonLooped" then
        rejectedByFilter = looped
    elseif CONFIG.FilterMode == "ThreatCandidate" then
        -- Broad unknown-ID mode: accept one-shots and looping Action-priority tracks.
        rejectedByFilter = looped and not actionTrack
    elseif CONFIG.FilterMode == "Whitelist" then
        rejectedByFilter = not isWhitelisted(animationId)
    elseif CONFIG.FilterMode == "All" then
        rejectedByFilter = false
    end
    if rejectedByFilter then
        -- Mark the track so the polling fallback does not count the same rejected track
        -- every 100 ms. Weak keys allow completed tracks to be collected.
        State.KnownTracks[track] = true
        State.Diagnostics.TracksRejected += 1
        State.Diagnostics.LastReject = CONFIG.FilterMode == "Whitelist" and "not in animation whitelist" or "looped animation"
        return
    end

    State.KnownTracks[track] = true

    -- Length == 0 is a normal Roblox loading state; keep the track and retry on Heartbeat.
    local record = {
        Player = player,
        Animator = animator,
        Track = track,
        AnimationId = animationId,
        Length = math.max(0, length),
        Speed = math.max(math.abs(speed), 0.01),
        Priority = priority,
        Looped = looped,
        StartedAt = os.clock(),
        Distance = math.huge,
        BlockTriggered = false,
        EventTriggered = false,
        EventConfirmed = false,
        DodgeTriggered = false,
        RecoveryTriggered = false,
        ZeroLengthTriggered = false,
        EligibleLogged = false,
        RejectLogged = false,
    }
    table.insert(State.ActiveTracks, record)

    -- Marker observer inspired by open animation-signal patterns. Marker names are
    -- observations only: they are not assumed to represent Revengers X hitboxes.
    if track and type(track.GetMarkerReachedSignal) == "function" then
        for _, markerName in ipairs({ "Hit", "Hit1", "Hit2", "Impact", "Damage", "Strike", "Hitbox", "Attack" }) do
            local okSignal, markerSignal = pcall(function()
                return track:GetMarkerReachedSignal(markerName)
            end)
            if okSignal and markerSignal then
                connect(markerSignal, function(markerValue)
                    local stamp = os.clock()
                    State.LastMarker = player.Name .. ":" .. markerName
                    State.LastMarkerAt = stamp
                    -- Marker observations remain internal; do not print remote-player animation IDs.
                end)
            end
        end
    end

    -- Event-driven fast path inspired by the AnimationPlayed listener pattern found
    -- in the reference source. Revalidate once after a tiny grace period: some games
    -- start and immediately cancel feint/transition tracks. No foreign game IDs/remotes
    -- are imported; the target and animation are validated against this script's config.
    if CONFIG.AutoBlock and CONFIG.ResponseMode == "Immediate"
        and ((not CONFIG.PriorityFilter) or actionTrack) then
        record.EventTriggered = true
        local _, targetHumanoid, targetRoot = getCharacterParts(player)
        local eligible, distance, rejectReason = isTargetEligible(player, targetHumanoid, targetRoot)
        if eligible then
            task.delay(math.max(0, tonumber(CONFIG.EventConfirmDelay) or 0), function()
                if State.Unloaded or not CONFIG.AutoBlock or record.EventConfirmed or record.BlockTriggered then return end
                local stillPlaying = false
                pcall(function() stillPlaying = track.IsPlaying end)
                if not stillPlaying then
                    State.Diagnostics.LastReject = "track cancelled during event confirmation"
                    return
                end
                local _, currentHumanoid, currentRoot = getCharacterParts(player)
                local stillEligible, currentDistance, currentReason, currentFacing, currentVelocity =
                    isTargetEligible(player, currentHumanoid, currentRoot)
                if not stillEligible then
                    State.Diagnostics.LastReject = currentReason or "target failed event re-check"
                    return
                end
                local now = os.clock()
                local hold = math.max(CONFIG.ZeroLengthHold, CONFIG.BlockHoldAfterImpact) + CONFIG.ComboGap
                record.EventConfirmed = true
                record.BlockTriggered = true
                record.Distance = currentDistance
                record.LastEligibleAt = now
                State.Diagnostics.LastTarget = player.Name
                State.Diagnostics.LastDistance = currentDistance
                State.Diagnostics.LastFacingDot = tonumber(currentFacing) or -1
                State.Diagnostics.LastVelocityDot = tonumber(currentVelocity) or -1
                State.LastThreatAt = now
                State.LastThreatPlayer = player
                requestBlock(now + hold, now, "validated AnimationPlayed event")
                setActionHeld("Block", CONFIG.BlockKey, true)
            end)
        else
            State.Diagnostics.LastReject = rejectReason or "target not eligible at AnimationPlayed"
        end
    end
end

local function attachAnimator(player, animator, bucket)
    if State.Unloaded or not animator then return end
    local isAnimator = false
    pcall(function() isAnimator = animator:IsA("Animator") end)
    if not isAnimator or State.WatchedAnimators[animator] then return end

    State.WatchedAnimators[animator] = { Player = player }
    State.Diagnostics.AnimatorsBound += 1
    debugLog("animator_" .. tostring(player.UserId) .. "_" .. tostring(animator),
        "watching Animator for player=" .. player.Name, 1.0)

    local onTrackPlayed = function(track)
        registerTrack(player, animator, track)
    end
    connect(animator.AnimationPlayed, onTrackPlayed, bucket)

    -- Older character controllers can expose the Humanoid-level event as well.
    -- It is optional and deduplicated by track identity when both signals fire.
    pcall(function()
        local parent = animator.Parent
        if parent and parent:IsA("Humanoid") and parent.AnimationPlayed then
            connect(parent.AnimationPlayed, onTrackPlayed, bucket)
        end
    end)

    -- Catch tracks that started before the event listener was attached.
    local playing = {}
    pcall(function() playing = animator:GetPlayingAnimationTracks() end)
    for _, track in ipairs(playing) do
        registerTrack(player, animator, track)
    end
end

local function bindCharacter(player, character)
    if State.Unloaded or not character then return end
    local previous = State.CharacterConnections[player]
    if previous then
        for _, connection in ipairs(previous) do pcall(function() connection:Disconnect() end) end
    end
    for animator, watch in pairs(State.WatchedAnimators) do
        if watch and watch.Player == player then
            State.WatchedAnimators[animator] = nil
            State.Diagnostics.AnimatorsBound = math.max(0, State.Diagnostics.AnimatorsBound - 1)
        end
    end
    State.CharacterConnections[player] = {}
    local bucket = State.CharacterConnections[player]

    local function inspect(instance)
        local isAnimator = false
        pcall(function() isAnimator = instance:IsA("Animator") end)
        if isAnimator then attachAnimator(player, instance, bucket) end
    end

    -- Watch all Animator instances, not only Humanoid.Animator. Some games put
    -- animation controllers in additional character descendants.
    local descendants = {}
    pcall(function() descendants = character:GetDescendants() end)
    for _, descendant in ipairs(descendants) do
        inspect(descendant)
    end
    connect(character.DescendantAdded, inspect, bucket)

    if not next(State.WatchedAnimators) then
        debugLog("no_animator_" .. tostring(player.UserId),
            "no Animator found yet for player=" .. player.Name .. "; waiting for DescendantAdded", 3.0)
    end
end

local function bindPlayer(player)
    if State.Unloaded or player == LocalPlayer or State.PlayerConnections[player] then return end
    local bucket = {}
    State.PlayerConnections[player] = bucket

    connect(player.CharacterAdded, function(character)
        bindCharacter(player, character)
    end, bucket)

    if player.Character then bindCharacter(player, player.Character) end
end

local function bindLocalCharacter(character)
    if State.Unloaded or not character then return end
    for _, connection in ipairs(State.LocalCharacterConnections) do
        pcall(function() connection:Disconnect() end)
    end
    State.LocalCharacterConnections = {}

    local watchedLocalAnimators = setmetatable({}, { __mode = "k" })
    local function logOwnAnimation(track, source)
        if State.Unloaded or not CONFIG.RecordSelfAnimations or not track then return end
        local animationId, animationName = "unknown", "unknown"
        local length, speed, position, priority, looped = 0, 1, 0, "Unknown", false
        pcall(function()
            local animation = track.Animation
            if animation then
                animationId = animation.AnimationId or "unknown"
                animationName = animation.Name or "unknown"
            end
            length = track.Length
            speed = track.Speed
            position = track.TimePosition
            priority = track.Priority
            looped = track.Looped
        end)
        animationId = tostring(animationId or "unknown")
        if animationId == "" then animationId = "unknown" end
        print(string.format(
            "[Aero V10 SELF] PLAY | name=%s | id=%s | length=%.3f | speed=%.2f | position=%.3f | priority=%s | looped=%s | source=%s",
            tostring(animationName), animationId, tonumber(length) or 0, tonumber(speed) or 1,
            tonumber(position) or 0, tostring(priority), tostring(looped), tostring(source or "AnimationPlayed")
        ))
    end

    local function attachOwnAnimator(animator)
        if State.Unloaded or not animator or watchedLocalAnimators[animator] then return end
        local isAnimator = false
        pcall(function() isAnimator = animator:IsA("Animator") end)
        if not isAnimator then return end
        watchedLocalAnimators[animator] = true
        connect(animator.AnimationPlayed, function(track)
            logOwnAnimation(track, "AnimationPlayed")
        end, State.LocalCharacterConnections)
    end

    local function inspectLocalDescendant(instance)
        local isAnimator = false
        pcall(function() isAnimator = instance:IsA("Animator") end)
        if isAnimator then attachOwnAnimator(instance) end
    end

    for _, descendant in ipairs(character:GetDescendants()) do
        inspectLocalDescendant(descendant)
    end
    connect(character.DescendantAdded, inspectLocalDescendant, State.LocalCharacterConnections)
    if CONFIG.RecordSelfAnimations then
        print("[Aero V10 SELF] Recorder ready. Perform your combo; your character's Animation IDs will appear below.")
    end

    local thread = task.spawn(function()
        local humanoid
        local ok = pcall(function() humanoid = character:WaitForChild("Humanoid", 6) end)
        if not ok or not humanoid or State.Unloaded or LocalPlayer.Character ~= character then return end
        local lastHealth
        pcall(function() lastHealth = humanoid.Health end)
        connect(humanoid.HealthChanged, function(health)
            if type(health) == "number" and type(lastHealth) == "number" and health < lastHealth then
                local now = os.clock()
                State.RecoveryUntil = math.max(State.RecoveryUntil, now + CONFIG.RecoveryWindow)
                if CONFIG.AutoBlock then
                    -- This is a post-hit fallback: it cannot prevent the hit already received,
                    -- but it guards immediately against follow-up hits during the combo window.
                    requestBlock(now + CONFIG.RecoveryBlockHold + CONFIG.ComboGap, now, "local health-loss recovery")
                end
                debugLog("health_loss", string.format("local health decreased: %.2f -> %.2f", lastHealth, health), 0.5)

                -- Damage-correlated timing still uses nearby opponent tracks internally;
                -- it no longer prints every opponent animation to the console.
                if CONFIG.LearnMode then
                    local bestRecord, bestScore = nil, math.huge
                    for _, candidate in ipairs(State.ActiveTracks) do
                        local freshness = now - (candidate.LastEligibleAt or -math.huge)
                        if freshness >= 0 and freshness <= 0.45
                            and candidate.Length > 0
                            and candidate.Distance <= CONFIG.LearnDistance
                            and isActionPriority(candidate.Priority) then
                            local playing, position
                            pcall(function()
                                playing = candidate.Track.IsPlaying
                                position = candidate.Track.TimePosition
                            end)
                            if playing and type(position) == "number" then
                                local score = freshness + (candidate.Distance * 0.003)
                                if score < bestScore then
                                    bestScore = score
                                    bestRecord = candidate
                                end
                            end
                        end
                    end

                    if bestRecord then
                        local id = tostring(bestRecord.AnimationId)
                        local observedPosition = 0
                        pcall(function() observedPosition = bestRecord.Track.TimePosition end)
                        local corrected = math.max(0, observedPosition - getPingSeconds())
                        local previous = CONFIG.LearnedTimings[id]
                        local learned = type(previous) == "number"
                            and (previous * 0.65 + corrected * 0.35)
                            or corrected
                        learned = clamp(learned, 0, bestRecord.Length)
                        CONFIG.LearnedTimings[id] = learned
                        print(string.format(
                            "[Aero Learn Hit] id=%s | observed-hit=%.3fs | length=%.3fs | speed=%.2f | distance=%.2f | damage-correlated estimate",
                            id, learned, bestRecord.Length, bestRecord.Speed, bestRecord.Distance
                        ))
                    end
                end
            end
            lastHealth = health
        end, State.LocalCharacterConnections)
    end)
    addThread(thread)
end

local function tryDodge(now, impactAt)
    if not CONFIG.AutoDodge then return false end
    DodgeCooldownGate.Duration = math.max(0, tonumber(CONFIG.DodgeCooldown) or 1.1)
    local cooldownReady = DodgeCooldownGate:Use(now, DodgeCooldownGate.Duration)
    if not cooldownReady then
        debugLog("dodge_cooldown", string.format("Dodge cooldown: %.2fs remaining", DodgeCooldownGate:Remaining(now)), 0.5)
        return false
    end

    -- Avoid overlapping a block and dodge keypress.
    setActionHeld("Block", CONFIG.BlockKey, false)
    local started = setActionHeld("Dodge", CONFIG.DodgeKey, true)
    if not started then
        DodgeCooldownGate:Reset()
        return false
    end

    State.LastDodgeAt = now
    State.DodgeUntil = now + CONFIG.DodgeTapDuration
    requestBlock(impactAt + CONFIG.BlockHoldAfterImpact + CONFIG.ComboGap, State.DodgeUntil)

    task.delay(CONFIG.DodgeTapDuration, function()
        if State.Unloaded then return end
        setActionHeld("Dodge", CONFIG.DodgeKey, false)
        State.DodgeUntil = 0
    end)
    return true
end

local function combatStep()
    if State.Unloaded then return end
    local now = os.clock()

    -- Poll as a fallback in case AnimationPlayed was missed or a track was already active
    -- when a character/Animator was attached.
    if now - State.LastAnimatorPoll >= CONFIG.AnimatorPollInterval then
        State.LastAnimatorPoll = now
        for animator, watch in pairs(State.WatchedAnimators) do
            local player = watch and watch.Player
            local valid = false
            pcall(function()
                valid = player ~= nil and player.Parent == Players
                    and player.Character ~= nil and animator:IsDescendantOf(player.Character)
            end)
            if not valid then
                State.WatchedAnimators[animator] = nil
                State.Diagnostics.AnimatorsBound = math.max(0, State.Diagnostics.AnimatorsBound - 1)
            else
                local playingTracks = {}
                pcall(function() playingTracks = animator:GetPlayingAnimationTracks() end)
                for _, activeTrack in ipairs(playingTracks) do
                    registerTrack(player, animator, activeTrack)
                end
            end
        end
    end

    if State.Diagnostics.TracksSeen == 0 and now - State.StartedAt > 8 then
        debugLog("no_tracks", "no opponent animation tracks have been observed yet; check whether the game replicates opponent animations", 5.0)
    end

    local recovery = isRecovering()
    local pingLead = getPingSeconds()
    local index = 1

    -- If a recent nearby attacker has already damaged us, keep guarding through recovery.
    if recovery and CONFIG.AutoBlock and State.LastThreatAt > 0
        and now - State.LastThreatAt <= CONFIG.RecoveryWindow then
        requestBlock(now + CONFIG.RecoveryBlockHold + CONFIG.ComboGap, now, "recent threat recovery")
    end

    while index <= #State.ActiveTracks do
        local record = State.ActiveTracks[index]
        local track = record.Track
        local keep = false
        local isPlaying, weightCurrent, timePosition, speed, loadedLength, currentPriority

        pcall(function()
            isPlaying = track.IsPlaying
            weightCurrent = track.WeightCurrent
            timePosition = track.TimePosition
            speed = track.Speed
            loadedLength = track.Length
            currentPriority = track.Priority
        end)

        local trackAlive = (isPlaying == true) or ((tonumber(weightCurrent) or 0) > 0.015)
        if trackAlive then
            keep = true
            if tonumber(loadedLength) and loadedLength > 0 then
                record.Length = loadedLength
            end
            if currentPriority then record.Priority = currentPriority end

            local _, attackerHumanoid, attackerRoot = getCharacterParts(record.Player)
            local learnEligible, learnDistance = isLearnTargetEligible(record.Player, attackerHumanoid, attackerRoot)
            if learnEligible then
                record.Distance = learnDistance
                record.LastEligibleAt = now
                State.LastThreatAt = now
                State.LastThreatPlayer = record.Player
            end

            local eligible, distance, rejectReason, facingDot, velocityDot = isTargetEligible(record.Player, attackerHumanoid, attackerRoot)
            if not eligible and rejectReason and string.find(rejectReason, "not aimed at local player", 1, true)
                and now - (record.LastEligibleAt or -math.huge) <= CONFIG.ThreatGrace then
                -- Small directional grace avoids dropping guard because root rotation jitters a few frames.
                eligible = true
                rejectReason = nil
            end
            if not eligible then
                State.Diagnostics.TracksRejected += record.RejectLogged and 0 or 1
                State.Diagnostics.LastReject = rejectReason or "target not eligible"
                if not record.RejectLogged then
                    record.RejectLogged = true
                    end
            end
            if eligible then
                if not record.EligibleLogged then
                    record.EligibleLogged = true
                    State.Diagnostics.TracksAccepted += 1
                end
                record.Distance = distance
                record.LastEligibleAt = now
                State.Diagnostics.LastTarget = record.Player.Name
                State.Diagnostics.LastDistance = distance
                State.Diagnostics.LastFacingDot = tonumber(facingDot) or -1
                State.Diagnostics.LastVelocityDot = tonumber(velocityDot) or -1
                if tonumber(speed) and math.abs(speed) > 0.001 then
                    record.Speed = math.abs(speed)
                end
                State.LastThreatAt = now
                State.LastThreatPlayer = record.Player

                local age = now - record.StartedAt
                local actionPriority = isActionPriority(record.Priority)
                local priorityAccepted = (not CONFIG.PriorityFilter) or actionPriority
                local safeSpeed = math.max(math.abs(tonumber(speed) or record.Speed), 0.01)

                if recovery and not record.RecoveryTriggered and CONFIG.AutoBlock then
                    record.RecoveryTriggered = true
                    requestBlock(now + CONFIG.RecoveryBlockHold + CONFIG.ComboGap, now, "hitstun recovery")
                end

                if priorityAccepted and age <= CONFIG.MaxTrackAge then
                    if CONFIG.ResponseMode == "Immediate" then
                        -- Wait for the AnimationPlayed event's brief confirmation pass before
                        -- holding block. This filters tracks that are cancelled almost instantly.
                        if CONFIG.AutoBlock and record.EventConfirmed then
                            local positionNow = math.max(0, tonumber(timePosition) or 0)
                            local remainingNow = CONFIG.ZeroLengthHold
                            if record.Length > 0 then
                                remainingNow = clamp((record.Length - positionNow) / safeSpeed, 0, CONFIG.MaxBlockCommit)
                            end
                            requestBlock(now + math.max(CONFIG.BlockHoldAfterImpact, remainingNow) + CONFIG.ComboGap,
                                now, record.Length > 0 and "confirmed nearby animation" or "confirmed animation length loading")
                            record.BlockTriggered = true
                        end
                    else
                        -- Timed mode retains estimated impact windows and optional dodge.
                        if CONFIG.EarlyActionGuard and actionPriority and CONFIG.AutoBlock then
                            local positionNow = math.max(0, tonumber(timePosition) or 0)
                            local remainingNow = record.Length > 0
                                and clamp((record.Length - positionNow) / safeSpeed, 0, CONFIG.MaxBlockCommit)
                                or CONFIG.ZeroLengthHold
                            requestBlock(now + math.max(CONFIG.BlockHoldAfterImpact, remainingNow) + CONFIG.ComboGap,
                                now, "timed early-action guard")
                            record.BlockTriggered = true
                        end

                        if record.Length <= 0 then
                            -- Refresh until Length becomes available; never issue a one-shot lease.
                            if CONFIG.ZeroLengthFallback and CONFIG.AutoBlock then
                                record.ZeroLengthTriggered = true
                                requestBlock(now + CONFIG.ZeroLengthHold + CONFIG.ComboGap,
                                    now, "timed animation length loading")
                            end
                        else
                            if not record.ImpactTime or record.ImpactLength ~= record.Length then
                                record.ImpactTime = estimateImpactTime(record.AnimationId, record.Length, track)
                                record.ImpactLength = record.Length
                            end
                            local impactTime = record.ImpactTime
                            local position = math.max(0, tonumber(timePosition) or 0)
                            local timeToImpact = (impactTime - position) / safeSpeed
                            local impactAt = now + math.max(0, timeToImpact)
                            local remainingTrack = clamp((record.Length - position) / safeSpeed, 0, CONFIG.MaxBlockCommit)
                            local blockUntil = now + math.max(CONFIG.BlockHoldAfterImpact, remainingTrack) + CONFIG.ComboGap
                            local blockLead = CONFIG.BlockLead + pingLead
                            local dodgeLead = CONFIG.DodgeLead + pingLead

                            if CONFIG.AutoDodge and not record.DodgeTriggered and timeToImpact <= dodgeLead then
                                record.DodgeTriggered = true
                                local dodged = tryDodge(now, impactAt)
                                if not dodged and CONFIG.AutoBlock then
                                    requestBlock(blockUntil, now, "dodge fallback to block")
                                    record.BlockTriggered = true
                                end
                            end

                            if CONFIG.AutoBlock and not record.BlockTriggered and timeToImpact <= blockLead then
                                record.BlockTriggered = true
                                requestBlock(blockUntil, now, "estimated impact window")
                            end
                        end
                    end
                end
            end
        end

        if not keep then
            State.KnownTracks[track] = nil
            table.remove(State.ActiveTracks, index)
        else
            index += 1
        end
    end

    if CONFIG.AutoBlock and now <= State.BlockWantedUntil
        and now >= State.BlockStartAt and now >= State.DodgeUntil then
        setActionHeld("Block", CONFIG.BlockKey, true)
    else
        setActionHeld("Block", CONFIG.BlockKey, false)
    end

    if UIRefs and UIRefs.SensorLabel and now - State.LastSensorRefresh >= CONFIG.SensorRefresh then
        State.LastSensorRefresh = now
        local d = State.Diagnostics
        local gate = d.LastReject or "waiting for opponent animation"
        local blockText = d.LastBlockReason or "none"
        pcall(function()
            UIRefs.SensorLabel.Text = string.format(
                "ANIMATORS %d   TRACKS %d   TARGETED %d   BLOCK CALLS %d\nLAST TARGET %s  |  DIST %.1f  |  FACING %.2f  |  MOVE %.2f\nLAST GATE %s  |  LAST BLOCK %s",
                d.AnimatorsBound, d.TracksSeen, d.TracksAccepted, d.BlockRequests,
                tostring(d.LastTarget), tonumber(d.LastDistance) or 0,
                tonumber(d.LastFacingDot) or -1, tonumber(d.LastVelocityDot) or -1,
                tostring(gate), tostring(blockText)
            )
        end)
    end
end

--==============================================================
-- UI Library (moody aurora / twilight interface)
--==============================================================

local COLORS = {
    Background = Color3.fromRGB(11, 11, 13),
    Panel = Color3.fromRGB(17, 17, 21),
    Panel2 = Color3.fromRGB(23, 23, 28),
    Text = Color3.fromRGB(242, 243, 247),
    Muted = Color3.fromRGB(132, 134, 145),
    Danger = Color3.fromRGB(245, 103, 121),
    White = Color3.fromRGB(255, 255, 255),
    Edge = Color3.fromRGB(53, 54, 63),
    AuroraA = Color3.fromRGB(220, 231, 255),
    AuroraB = Color3.fromRGB(164, 179, 218),
    AuroraC = Color3.fromRGB(194, 168, 220),
    AuroraD = Color3.fromRGB(133, 166, 195),
}

local function accentColor()
    return Color3.fromRGB(
        math.floor(clamp(CONFIG.Accent[1] or 242, 0, 255)),
        math.floor(clamp(CONFIG.Accent[2] or 244, 0, 255)),
        math.floor(clamp(CONFIG.Accent[3] or 248, 0, 255))
    )
end

local GUI
local Main
local Header
local Content
local Pages = {}
local TabButtons = {}
local ToastHolder
local AccentTargets = {}
UIRefs = { Refreshers = {} }

local function addAccentTarget(instance, property)
    table.insert(AccentTargets, { Instance = instance, Property = property })
end

local function applyTheme()
    local accent = accentColor()
    for _, item in ipairs(AccentTargets) do
        if item.Instance and item.Instance.Parent then
            pcall(function() item.Instance[item.Property] = accent end)
        end
    end
    if Main then
        pcall(function() Main.BackgroundTransparency = CONFIG.WindowTransparency end)
    end
    for configKey, button in pairs(UIRefs.ToggleButtons or {}) do
        pcall(function()
            button.BackgroundColor3 = CONFIG[configKey] and accent or COLORS.Panel2
            button:SetAttribute("AeroIdleColor", button.BackgroundColor3)
        end)
    end
    for tabName, button in pairs(TabButtons) do
        pcall(function()
            local selected = tabName == State.CurrentTab
            button.BackgroundColor3 = selected and Color3.fromRGB(35, 36, 43) or COLORS.Panel
            button.TextColor3 = selected and COLORS.White or COLORS.Muted
            pcall(function() button:SetAttribute("AeroIdleColor", button.BackgroundColor3) end)
            local indicator = UIRefs.TabIndicators and UIRefs.TabIndicators[tabName]
            if indicator then indicator.BackgroundColor3 = accent; indicator.BackgroundTransparency = selected and 0 or 1 end
        end)
    end
    if UIRefs.Gradient then
        pcall(function() UIRefs.Gradient.Enabled = CONFIG.AnimateHeader end)
    end
    if UIRefs.Shimmer then
        pcall(function() UIRefs.Shimmer.Enabled = CONFIG.AnimateHeader end)
    end
end

local function create(className, properties, parent)
    local instance
    local ok = pcall(function()
        instance = Instance.new(className)
        for property, value in pairs(properties or {}) do
            instance[property] = value
        end
        if parent then instance.Parent = parent end
    end)
    if not ok and instance then pcall(function() instance:Destroy() end); return nil end
    return instance
end

local function corner(parent, radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent)
end

local function stroke(parent, color, transparency)
    return create("UIStroke", {
        Color = color or Color3.fromRGB(54, 57, 72),
        Thickness = 1,
        Transparency = transparency or 0.2,
    }, parent)
end

local function tween(instance, duration, properties, style, direction)
    if not TweenService or not instance then return end
    local ok, animation = pcall(function()
        return TweenService:Create(instance, TweenInfo.new(
            duration,
            style or Enum.EasingStyle.Quint,
            direction or Enum.EasingDirection.Out
        ), properties)
    end)
    if ok and animation then pcall(function() animation:Play() end) end
end

local function makeLabel(parent, text, size, color, font)
    return create("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = color or COLORS.Text,
        TextSize = size or 13,
        Font = font or Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Size = UDim2.new(1, 0, 0, 22),
    }, parent)
end

local function makeButton(parent, text, callback, width)
    local button = create("TextButton", {
        AutoButtonColor = false,
        BackgroundColor3 = COLORS.Panel2,
        BorderSizePixel = 0,
        Size = UDim2.new(0, width or 112, 0, 31),
        Text = text,
        TextColor3 = COLORS.Text,
        TextSize = 12,
        Font = Enum.Font.GothamSemibold,
    }, parent)
    if not button then return nil end
    corner(button, 8)
    pcall(function() button:SetAttribute("AeroIdleColor", COLORS.Panel2) end)
    stroke(button, COLORS.Edge, 0.48)
    create("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(47, 58, 79)),
            ColorSequenceKeypoint.new(0.52, Color3.fromRGB(30, 42, 64)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 29, 45)),
        }),
    }, button)
    connect(button.MouseButton1Click, function()
        if not State.Unloaded and callback then
            tween(button, 0.08, { BackgroundColor3 = Color3.fromRGB(55, 57, 63) })
            callback()
        end
    end)
    connect(button.MouseEnter, function()
        tween(button, 0.14, { BackgroundColor3 = Color3.fromRGB(48, 50, 56) })
    end)
    connect(button.MouseLeave, function()
        local idle = COLORS.Panel2
        pcall(function() idle = button:GetAttribute("AeroIdleColor") or COLORS.Panel2 end)
        tween(button, 0.18, { BackgroundColor3 = idle })
    end)
    return button
end

local function toast(message, kind)
    if State.Unloaded or not ToastHolder then return end
    local color = kind == "error" and COLORS.Danger or accentColor()
    local item = create("Frame", {
        BackgroundColor3 = COLORS.Panel2,
        BackgroundTransparency = 0.04,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 34),
        Position = UDim2.new(1, 24, 0, 0),
    }, ToastHolder)
    if not item then return end
    corner(item, 8)
    stroke(item, color, 0.25)
    local bar = create("Frame", {
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Size = UDim2.new(0, 3, 1, -12),
        Position = UDim2.new(0, 7, 0, 6),
    }, item)
    corner(bar, 2)
    local label = makeLabel(item, tostring(message), 11, COLORS.Text)
    label.Position = UDim2.new(0, 17, 0, 0)
    label.Size = UDim2.new(1, -24, 1, 0)
    tween(item, 0.22, { Position = UDim2.new(0, 0, 0, 0) })
    task.delay(2.25, function()
        if item and item.Parent then
            tween(item, 0.18, { Position = UDim2.new(1, 24, 0, 0), BackgroundTransparency = 1 })
            task.delay(0.20, function() pcall(function() item:Destroy() end) end)
        end
    end)
end

local function pageSection(page, title)
    local data = UIRefs.PageData and UIRefs.PageData[page]
    local target = page
    if data then
        local index = data.Heights[1] <= data.Heights[2] and 1 or 2
        data.Active = index
        target = data.Columns[index]
        data.Heights[index] = data.Heights[index] + 30
    end
    local holder = create("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -4, 0, 23),
    }, target)
    local label = makeLabel(holder, string.upper(title), 10, COLORS.White, Enum.Font.GothamBold)
    label.Size = UDim2.new(0, 220, 1, 0)
    local rule = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(75, 77, 88),
        BackgroundTransparency = 0.42,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -1),
        Size = UDim2.new(1, 0, 0, 1),
    }, holder)
    return holder
end

local function pageRow(page, height)
    local data = UIRefs.PageData and UIRefs.PageData[page]
    local target = page
    if data then
        local index = data.Active or 1
        target = data.Columns[index]
        data.Heights[index] = data.Heights[index] + (height or 42) + 7
    end
    local row = create("Frame", {
        BackgroundColor3 = COLORS.Panel,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -3, 0, height or 42),
    }, target)
    corner(row, 8)
    stroke(row, Color3.fromRGB(47, 48, 56), 0.38)
    return row
end

local function addToggle(page, title, configKey)
    local row = pageRow(page, 39)
    local label = makeLabel(row, title, 12, COLORS.Text, Enum.Font.GothamMedium)
    label.Position = UDim2.new(0, 12, 0, 0)
    label.Size = UDim2.new(1, -100, 1, 0)
    local button
    button = makeButton(row, "", function()
        CONFIG[configKey] = not CONFIG[configKey]
        local enabled = CONFIG[configKey]
        button.Text = enabled and "ON" or "OFF"
        button.BackgroundColor3 = enabled and accentColor() or COLORS.Panel2
        pcall(function() button:SetAttribute("AeroIdleColor", button.BackgroundColor3) end)
        toast(title .. (enabled and " enabled" or " disabled"))
        if configKey == "LearnMode" then toast(enabled and "Learn mode: check F9 console" or "Learn mode stopped") end
        if configKey == "AnimateHeader" then applyTheme() end
    end, 62)
    button.Position = UDim2.new(1, -74, 0.5, -13)
    button.Size = UDim2.fromOffset(62, 26)
    UIRefs.ToggleButtons = UIRefs.ToggleButtons or {}
    UIRefs.ToggleButtons[configKey] = button
    local function refresh()
        button.Text = CONFIG[configKey] and "ON" or "OFF"
        button.BackgroundColor3 = CONFIG[configKey] and accentColor() or COLORS.Panel2
        pcall(function() button:SetAttribute("AeroIdleColor", button.BackgroundColor3) end)
    end
    UIRefs.Refreshers[configKey] = refresh
    refresh()
    return row
end

local function addBind(page, title, configKey)
    local row = pageRow(page, 39)
    local label = makeLabel(row, title, 12, COLORS.Text, Enum.Font.GothamMedium)
    label.Position = UDim2.new(0, 12, 0, 0)
    label.Size = UDim2.new(1, -112, 1, 0)
    local button
    button = makeButton(row, CONFIG[configKey], function()
        State.BindingTarget = configKey
        button.Text = "PRESS KEY"
        toast("Press a key for " .. title)
    end, 92)
    button.Position = UDim2.new(1, -104, 0.5, -15)
    UIRefs.BindButtons = UIRefs.BindButtons or {}
    UIRefs.BindButtons[configKey] = button
    UIRefs.Refreshers[configKey] = function() button.Text = CONFIG[configKey] end
    return row
end

local function addSlider(page, title, configKey, minimum, maximum, decimals, onChanged)
    local row = pageRow(page, 54)
    local label = makeLabel(row, title, 11, COLORS.Text, Enum.Font.GothamMedium)
    label.Position = UDim2.new(0, 11, 0, 2)
    label.Size = UDim2.new(1, -78, 0, 20)
    local valueLabel = makeLabel(row, "", 10, COLORS.Muted, Enum.Font.Gotham)
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.Position = UDim2.new(1, -66, 0, 2)
    valueLabel.Size = UDim2.new(0, 55, 0, 20)
    local bar = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(44, 57, 81),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 11, 0, 31),
        Size = UDim2.new(1, -22, 0, 8),
    }, row)
    corner(bar, 5)
    local fill = create("Frame", {
        BackgroundColor3 = accentColor(),
        BorderSizePixel = 0,
        Size = UDim2.new(0, 0, 1, 0),
    }, bar)
    corner(fill, 5)
    addAccentTarget(fill, "BackgroundColor3")

    local function render()
        local value = tonumber(CONFIG[configKey]) or minimum
        local alpha = clamp((value - minimum) / (maximum - minimum), 0, 1)
        fill.Size = UDim2.new(alpha, 0, 1, 0)
        local fmt = decimals == 0 and "%d" or ("%." .. tostring(decimals) .. "f")
        valueLabel.Text = string.format(fmt, value)
    end

    local function setFromX(x)
        local width = math.max(bar.AbsoluteSize.X, 1)
        local alpha = clamp((x - bar.AbsolutePosition.X) / width, 0, 1)
        local raw = minimum + ((maximum - minimum) * alpha)
        local multiplier = 10 ^ (decimals or 0)
        raw = math.floor(raw * multiplier + 0.5) / multiplier
        CONFIG[configKey] = raw
        render()
        if onChanged then onChanged(raw) end
    end

    connect(bar.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            State.SliderDrag = { Set = setFromX }
            setFromX(input.Position.X)
        end
    end)
    UIRefs.Refreshers[configKey] = render
    render()
    return row
end

local function addCycle(page, title, configKey, choices)
    local row = pageRow(page, 39)
    local label = makeLabel(row, title, 12, COLORS.Text, Enum.Font.GothamMedium)
    label.Position = UDim2.new(0, 12, 0, 0)
    label.Size = UDim2.new(1, -130, 1, 0)
    local button
    local function update()
        button.Text = tostring(CONFIG[configKey])
    end
    button = makeButton(row, tostring(CONFIG[configKey]), function()
        local current = 1
        for i, choice in ipairs(choices) do
            if choice == CONFIG[configKey] then current = i break end
        end
        current += 1
        if current > #choices then current = 1 end
        CONFIG[configKey] = choices[current]
        update()
        toast(title .. ": " .. tostring(CONFIG[configKey]))
    end, 112)
    button.Position = UDim2.new(1, -124, 0.5, -15)
    UIRefs.Refreshers[configKey] = update
    update()
    return row
end

local function addAction(page, title, callback)
    local row = pageRow(page, 42)
    local label = makeLabel(row, title, 12, COLORS.Text, Enum.Font.GothamMedium)
    label.Position = UDim2.new(0, 12, 0, 0)
    label.Size = UDim2.new(1, -132, 1, 0)
    local button = makeButton(row, "RUN", callback, 86)
    button.Position = UDim2.new(1, -98, 0.5, -15)
    return row
end

local function createPage(name)
    local page = create("Frame", {
        Name = name .. "Page",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 1, 0),
        Visible = false,
    }, Content)
    local columns = {}
    for i = 1, 2 do
        local column = create("ScrollingFrame", {
            Name = "Column" .. tostring(i),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Position = UDim2.new((i - 1) * 0.5, i == 1 and 0 or 5, 0, 0),
            Size = UDim2.new(0.5, -7, 1, 0),
            CanvasSize = UDim2.new(0, 0, 0, 0),
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = Color3.fromRGB(177, 183, 198),
            AutomaticCanvasSize = Enum.AutomaticSize.None,
        }, page)
        create("UIListLayout", {
            Padding = UDim.new(0, 7),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, column)
        create("UIPadding", {
            PaddingTop = UDim.new(0, 3),
            PaddingBottom = UDim.new(0, 8),
            PaddingLeft = UDim.new(0, 2),
            PaddingRight = UDim.new(0, 5),
        }, column)
        local layout = column:FindFirstChildOfClass("UIListLayout")
        connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
            if column and column.Parent then
                column.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 12)
            end
        end)
        columns[i] = column
    end
    UIRefs.PageData = UIRefs.PageData or {}
    UIRefs.PageData[page] = { Columns = columns, Heights = { 0, 0 }, Active = 1 }
    Pages[name] = page
    return page
end

local function setTab(name)
    State.CurrentTab = name
    for pageName, page in pairs(Pages) do
        if pageName == name then
            page.Visible = true
            page.Position = UDim2.new(0, 9, 0, 0)
            tween(page, 0.20, { Position = UDim2.new(0, 0, 0, 0) }, Enum.EasingStyle.Quint)
        else
            page.Visible = false
        end
    end
    for tabName, button in pairs(TabButtons) do
        local selected = tabName == name
        button.BackgroundColor3 = selected and Color3.fromRGB(35, 36, 43) or COLORS.Panel
        button.TextColor3 = selected and COLORS.White or COLORS.Muted
        local indicator = UIRefs.TabIndicators and UIRefs.TabIndicators[tabName]
        if indicator then
            tween(indicator, 0.16, { BackgroundTransparency = selected and 0 or 1, BackgroundColor3 = accentColor() })
        end
    end
end

local function setMenuVisible(visible)
    if State.Unloaded or not Main then return end
    State.MenuOpen = visible
    if visible then
        Main.Visible = true
        Main.Size = UDim2.fromOffset(0, 0)
        Main.BackgroundTransparency = 1
        tween(Main, 0.34, {
            Size = UDim2.fromOffset(700, 520),
            BackgroundTransparency = CONFIG.WindowTransparency,
        }, Enum.EasingStyle.Back)
    else
        tween(Main, 0.22, { Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 1 }, Enum.EasingStyle.Quint)
        task.delay(0.23, function()
            if Main and not State.MenuOpen then Main.Visible = false end
        end)
    end
end

local function makeUI()
    local parent
    local gethuiFn = capability("gethui")
    if type(gethuiFn) == "function" then
        local ok, result = pcall(gethuiFn)
        if ok then parent = result end
    end
    if not parent then parent = CoreGui end
    if not parent then
        pcall(function() parent = LocalPlayer:FindFirstChildOfClass("PlayerGui") end)
    end
    if not parent then
        notifyWarn("No GUI parent available; combat core remains active without UI.")
        return
    end

    pcall(function()
        local old = parent:FindFirstChild("Aero_RevengersX")
        if old then old:Destroy() end
    end)

    GUI = create("ScreenGui", {
        Name = "Aero_RevengersX",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    }, parent)
    if not GUI then return end

    -- Soft shadow sits behind the main window.
    local shadow = create("ImageLabel", {
        Name = "WindowShadow",
        BackgroundTransparency = 1,
        Position = UDim2.new(0.5, -365, 0.5, -275),
        Size = UDim2.fromOffset(730, 550),
        Image = "rbxassetid://1316045217",
        ImageColor3 = Color3.fromRGB(0, 0, 0),
        ImageTransparency = 0.34,
        ScaleType = Enum.ScaleType.Slice,
        SliceCenter = Rect.new(10, 10, 118, 118),
        ZIndex = 0,
    }, GUI)

    Main = create("Frame", {
        Name = "Main",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(700, 520),
        BackgroundColor3 = COLORS.Background,
        BackgroundTransparency = CONFIG.WindowTransparency,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        ZIndex = 1,
    }, GUI)
    corner(Main, 14)
    local outerStroke = stroke(Main, COLORS.AuroraA, 0.10)
    if outerStroke then
        outerStroke.Thickness = 1.2
        UIRefs.BorderGradient = create("UIGradient", {
            Rotation = 0,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, COLORS.AuroraA),
                ColorSequenceKeypoint.new(0.28, COLORS.AuroraD),
                ColorSequenceKeypoint.new(0.62, COLORS.AuroraC),
                ColorSequenceKeypoint.new(1, COLORS.AuroraB),
            }),
        }, outerStroke)
    end

    -- Sidebar based on the supplied Mercedes-style layout; only the visual language is reused.
    local sidebar = create("Frame", {
        Name = "Sidebar",
        BackgroundColor3 = Color3.fromRGB(14, 14, 17),
        BorderSizePixel = 0,
        Size = UDim2.new(0, 155, 1, 0),
        ZIndex = 2,
    }, Main)
    corner(sidebar, 14)
    create("Frame", {
        BackgroundColor3 = Color3.fromRGB(14, 14, 17),
        BorderSizePixel = 0,
        Position = UDim2.new(1, -14, 0, 0),
        Size = UDim2.new(0, 14, 1, 0),
        ZIndex = 2,
    }, sidebar)

    local logo = create("Frame", {
        Name = "AeroMark",
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 17, 0, 17),
        Size = UDim2.fromOffset(24, 24),
    }, sidebar)
    local logoCircle = create("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
    }, logo)
    corner(logoCircle, 12)
    stroke(logoCircle, COLORS.White, 0.05).Thickness = 1.35
    local pivot = create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(0, 0),
    }, logo)
    for _, angle in ipairs({ 0, 120, -120 }) do
        local rayHolder = create("Frame", {
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromOffset(0, 0),
            Rotation = angle,
        }, pivot)
        create("Frame", {
            BackgroundColor3 = COLORS.White,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 1),
            Position = UDim2.fromOffset(0, 0),
            Size = UDim2.fromOffset(1.4, 10.5),
        }, rayHolder)
    end
    local cap = create("Frame", {
        BackgroundColor3 = COLORS.White,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(2, 2),
    }, logo)
    corner(cap, 2)

    local brand = makeLabel(sidebar, "AERO", 16, COLORS.White, Enum.Font.GothamBold)
    brand.Position = UDim2.new(0, 49, 0, 17)
    brand.Size = UDim2.new(0, 92, 0, 24)
    local brandSub = makeLabel(sidebar, "REVENGERS X", 8, COLORS.Muted, Enum.Font.GothamMedium)
    brandSub.Position = UDim2.new(0, 49, 0, 36)
    brandSub.Size = UDim2.new(0, 92, 0, 12)

    local navTitle = makeLabel(sidebar, "WORKSPACE", 9, Color3.fromRGB(95, 97, 108), Enum.Font.GothamBold)
    navTitle.Position = UDim2.new(0, 18, 0, 76)
    navTitle.Size = UDim2.new(1, -30, 0, 16)

    local nav = create("Frame", {
        Name = "Navigation",
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 13, 0, 99),
        Size = UDim2.new(1, -25, 0, 132),
    }, sidebar)
    create("UIListLayout", {
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, nav)
    UIRefs.TabIndicators = {}
    for _, tabName in ipairs({ "Combat", "Settings", "Theme" }) do
        local button = create("TextButton", {
            Name = tabName .. "Tab",
            AutoButtonColor = false,
            BackgroundColor3 = COLORS.Panel,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 36),
            Text = "   " .. string.upper(tabName),
            TextColor3 = COLORS.Muted,
            TextSize = 11,
            Font = Enum.Font.GothamSemibold,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, nav)
        corner(button, 7)
        local indicator = create("Frame", {
            BackgroundColor3 = COLORS.White,
            BorderSizePixel = 0,
            Position = UDim2.new(0, 0, 0.5, -8),
            Size = UDim2.fromOffset(2, 16),
            BackgroundTransparency = 1,
        }, button)
        corner(indicator, 2)
        TabButtons[tabName] = button
        UIRefs.TabIndicators[tabName] = indicator
        connect(button.MouseButton1Click, function() setTab(tabName) end)
        connect(button.MouseEnter, function()
            if State.CurrentTab ~= tabName then tween(button, 0.12, { BackgroundColor3 = Color3.fromRGB(28, 28, 34) }) end
        end)
        connect(button.MouseLeave, function()
            if State.CurrentTab ~= tabName then tween(button, 0.12, { BackgroundColor3 = COLORS.Panel }) end
        end)
    end

    local profile = create("Frame", {
        Name = "ProfileFrame",
        BackgroundColor3 = Color3.fromRGB(19, 19, 23),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 12, 1, -54),
        Size = UDim2.new(1, -24, 0, 40),
    }, sidebar)
    corner(profile, 8)
    stroke(profile, COLORS.Edge, 0.55)
    local avatar = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(37, 39, 47),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 7, 0, 7),
        Size = UDim2.fromOffset(26, 26),
    }, profile)
    corner(avatar, 13)
    local initials = makeLabel(avatar, string.sub(tostring(LocalPlayer.DisplayName or LocalPlayer.Name), 1, 1), 12, COLORS.White, Enum.Font.GothamBold)
    initials.TextXAlignment = Enum.TextXAlignment.Center
    initials.Size = UDim2.fromScale(1, 1)
    local profileName = makeLabel(profile, tostring(LocalPlayer.DisplayName or LocalPlayer.Name), 10, COLORS.White, Enum.Font.GothamSemibold)
    profileName.Position = UDim2.new(0, 40, 0, 5)
    profileName.Size = UDim2.new(1, -46, 0, 14)
    local profileSub = makeLabel(profile, "CLIENT SESSION", 8, COLORS.Muted, Enum.Font.Gotham)
    profileSub.Position = UDim2.new(0, 40, 0, 20)
    profileSub.Size = UDim2.new(1, -46, 0, 12)

    -- Main content header doubles as the draggable handle.
    Header = create("Frame", {
        Name = "HeaderDragBar",
        BackgroundColor3 = Color3.fromRGB(16, 16, 20),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 169, 0, 13),
        Size = UDim2.new(1, -182, 0, 52),
        ZIndex = 2,
    }, Main)
    corner(Header, 9)
    stroke(Header, Color3.fromRGB(46, 47, 56), 0.48)
    local title = makeLabel(Header, "DEFENSE CONTROL", 14, COLORS.Text, Enum.Font.GothamBold)
    title.Position = UDim2.new(0, 14, 0, 4)
    title.Size = UDim2.new(0, 245, 0, 23)
    UIRefs.Title = title
    UIRefs.Gradient = create("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, COLORS.AuroraA),
            ColorSequenceKeypoint.new(0.45, COLORS.AuroraD),
            ColorSequenceKeypoint.new(1, COLORS.AuroraC),
        }),
        Rotation = 0,
        Offset = Vector2.new(-0.55, 0),
        Enabled = CONFIG.AnimateHeader,
    }, title)
    local subtitle = makeLabel(Header, "TACTICAL INPUT  /  LIVE ANIMATION SENSOR", 8, COLORS.Muted, Enum.Font.GothamMedium)
    subtitle.Position = UDim2.new(0, 15, 0, 27)
    subtitle.Size = UDim2.new(0, 285, 0, 13)

    local shimmer = create("Frame", {
        Name = "ShimmerLine",
        BackgroundColor3 = COLORS.White,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -2),
        Size = UDim2.new(1, 0, 0, 2),
    }, Header)
    UIRefs.Shimmer = create("UIGradient", {
        Rotation = 0,
        Offset = Vector2.new(-1, 0),
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, COLORS.AuroraA),
            ColorSequenceKeypoint.new(0.38, COLORS.AuroraD),
            ColorSequenceKeypoint.new(0.70, COLORS.AuroraC),
            ColorSequenceKeypoint.new(1, COLORS.AuroraB),
        }),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.42, 1),
            NumberSequenceKeypoint.new(0.50, 0.04),
            NumberSequenceKeypoint.new(0.58, 1),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Enabled = CONFIG.AnimateHeader,
    }, shimmer)

    local statusPill = create("Frame", {
        Name = "StatusPill",
        BackgroundColor3 = Color3.fromRGB(26, 27, 33),
        BorderSizePixel = 0,
        Position = UDim2.new(1, -128, 0, 12),
        Size = UDim2.fromOffset(78, 25),
    }, Header)
    corner(statusPill, 12)
    stroke(statusPill, COLORS.Edge, 0.38)
    local statusDot = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(190, 224, 205),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 9, 0.5, -3),
        Size = UDim2.fromOffset(6, 6),
    }, statusPill)
    corner(statusDot, 4)
    local statusText = makeLabel(statusPill, "READY", 8, COLORS.Text, Enum.Font.GothamBold)
    statusText.Position = UDim2.new(0, 22, 0, 0)
    statusText.Size = UDim2.new(1, -25, 1, 0)

    local close = makeButton(Header, "—", function() setMenuVisible(false) end, 28)
    close.Position = UDim2.new(1, -43, 0, 11)
    close.Size = UDim2.fromOffset(27, 26)
    local unloadButton = makeButton(Header, "×", function()
        if type(_G.AERO_REVENGERS_UNLOAD) == "function" then _G.AERO_REVENGERS_UNLOAD() end
    end, 28)
    unloadButton.Position = UDim2.new(1, -75, 0, 11)
    unloadButton.Size = UDim2.fromOffset(27, 26)
    unloadButton.TextColor3 = COLORS.Danger

    Content = create("Frame", {
        Name = "ContentHost",
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 169, 0, 76),
        Size = UDim2.new(1, -182, 1, -90),
    }, Main)

    ToastHolder = create("Frame", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -16, 0, 16),
        Size = UDim2.new(0, 230, 0, 120),
        ZIndex = 20,
    }, GUI)
    create("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Top,
    }, ToastHolder)

    local combat = createPage("Combat")
    local settings = createPage("Settings")
    local theme = createPage("Theme")

    -- Combat: existing Aero controls only; no features from the supplied cheat are imported.
    pageSection(combat, "Live threat sensor")
    local sensorCard = pageRow(combat, 78)
    local sensorLabel = makeLabel(sensorCard,
        "ANIMATORS 0   TRACKS 0   TARGETED 0   BLOCK CALLS 0\nLAST TARGET none  |  DIST 0.0  |  FACING -1.00  |  MOVE -1.00\nLAST GATE waiting for opponent animation  |  LAST BLOCK none",
        8, COLORS.Muted, Enum.Font.Code)
    sensorLabel.Position = UDim2.new(0, 9, 0, 4)
    sensorLabel.Size = UDim2.new(1, -16, 1, -8)
    sensorLabel.TextWrapped = true
    sensorLabel.TextYAlignment = Enum.TextYAlignment.Center
    UIRefs.SensorLabel = sensorLabel

    pageSection(combat, "Defense")
    addToggle(combat, "Auto Block", "AutoBlock")
    addBind(combat, "Block key", "BlockKey")
    addToggle(combat, "Auto Parry / Dodge", "AutoDodge")
    addBind(combat, "Dodge key", "DodgeKey")
    addCycle(combat, "Response mode", "ResponseMode", { "Immediate", "Timed" })
    addToggle(combat, "Require attack aimed at me", "FacingCheck")
    addToggle(combat, "Ignore same Roblox Team", "IgnoreSameTeam")
    addToggle(combat, "Ping compensation", "PingCompensation")
    addToggle(combat, "Post-hit recovery", "RecoveryEnabled")

    pageSection(combat, "Detection tuning")
    addSlider(combat, "Max threat distance", "MaxDistance", 5, 40, 0)
    addSlider(combat, "Block lead (sec)", "BlockLead", 0.05, 0.60, 2)
    addSlider(combat, "Facing threshold", "FacingDot", -0.35, 0.9, 2)
    addSlider(combat, "Move-toward threshold", "VelocityTowardDot", -0.25, 0.95, 2)
    addSlider(combat, "Minimum attacker speed", "MinAttackerSpeed", 0.5, 12, 1)
    addSlider(combat, "Learn distance", "LearnDistance", 5, 35, 0)
    addToggle(combat, "Immediate fallback while Length loads", "ZeroLengthFallback")
    addToggle(combat, "Use named hit keyframes", "UseKeyframeMarkers")
    addToggle(combat, "Early guard on Action animations", "EarlyActionGuard")
    addCycle(combat, "Animation filter", "FilterMode", { "ThreatCandidate", "NonLooped", "All", "Whitelist" })

    local whitelistRow = pageRow(combat, 42)
    local whitelistBox = create("TextBox", {
        BackgroundColor3 = COLORS.Panel2,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        PlaceholderText = "Animation IDs, comma-separated",
        Text = table.concat(CONFIG.AttackWhitelist, ","),
        TextColor3 = COLORS.Text,
        PlaceholderColor3 = COLORS.Muted,
        TextSize = 9,
        Font = Enum.Font.Gotham,
        Position = UDim2.new(0, 7, 0, 6),
        Size = UDim2.new(1, -82, 0, 29),
    }, whitelistRow)
    corner(whitelistBox, 6)
    local applyWhitelist = makeButton(whitelistRow, "APPLY", function()
        local ids = {}
        for token in string.gmatch(whitelistBox.Text, "[^,]+") do
            local id = string.gsub(token, "%s+", "")
            if id ~= "" then table.insert(ids, id) end
        end
        CONFIG.AttackWhitelist = ids
        toast("Whitelist updated: " .. tostring(#ids) .. " IDs")
    end, 66)
    applyWhitelist.Position = UDim2.new(1, -73, 0.5, -14)

    pageSection(combat, "Tools")
    addToggle(combat, "Record my animations", "RecordSelfAnimations")
    addToggle(combat, "Learn mode", "LearnMode")
    addAction(combat, "Test block input", function()
        if pulseAction("Block", CONFIG.BlockKey, 0.16) then toast("Block input sent") else toast("Block input unavailable", "error") end
    end)
    addAction(combat, "Test dodge input", function()
        if pulseAction("Dodge", CONFIG.DodgeKey, CONFIG.DodgeTapDuration) then toast("Dodge input sent") else toast("Dodge input unavailable", "error") end
    end)
    addAction(combat, "Reset learned timings", function()
        CONFIG.LearnedTimings = {}
        State.LastLearnLog = {}
        toast("Learned timing estimates cleared")
    end)
    addAction(combat, "Print combat diagnostics", function()
        local d = State.Diagnostics
        print(string.format(
            "[Aero Status] animators=%d tracksSeen=%d tracksAccepted=%d tracksRejected=%d blockRequests=%d target=%s distance=%.1f facing=%.2f velocity=%.2f lastReject=%s lastBlock=%s",
            d.AnimatorsBound, d.TracksSeen, d.TracksAccepted, d.TracksRejected, d.BlockRequests,
            tostring(d.LastTarget), tonumber(d.LastDistance) or 0,
            tonumber(d.LastFacingDot) or -1, tonumber(d.LastVelocityDot) or -1,
            tostring(d.LastReject), tostring(d.LastBlockReason)
        ))
        toast("Diagnostics printed to console")
    end)

    -- Settings: preserve only Aero's current settings and lifecycle actions.
    pageSection(settings, "Input backend")
    addCycle(settings, "Input mode", "InputMode", { "Auto", "Key", "Remote" })
    addCycle(settings, "Key sender", "InputMethod", { "VIM", "keypress", "both" })
    addBind(settings, "Menu hotkey", "MenuKey")
    pageSection(settings, "Reliability")
    addSlider(settings, "Dodge cooldown (sec)", "DodgeCooldown", 0.25, 3.0, 2)
    addSlider(settings, "Dodge tap (sec)", "DodgeTapDuration", 0.05, 0.30, 2)
    addSlider(settings, "Combo gap (sec)", "ComboGap", 0.05, 0.80, 2)
    addSlider(settings, "Max block commitment (sec)", "MaxBlockCommit", 0.20, 2.50, 2)
    addSlider(settings, "Manual ping fallback (ms)", "ManualPingMs", 0, 300, 0)
    addAction(settings, "Save config (JSON)", function()
        local writeFn = capability("writefile")
        if type(writeFn) ~= "function" or not HttpService then toast("writefile unavailable", "error"); return end
        local data = {
            Version = CONFIG.Version, MenuKey = CONFIG.MenuKey, BlockKey = CONFIG.BlockKey, DodgeKey = CONFIG.DodgeKey,
            AutoBlock = CONFIG.AutoBlock, AutoDodge = CONFIG.AutoDodge, ResponseMode = CONFIG.ResponseMode,
            IgnoreSameTeam = CONFIG.IgnoreSameTeam, FacingCheck = CONFIG.FacingCheck, FacingDot = CONFIG.FacingDot,
            MaxDistance = CONFIG.MaxDistance, PingCompensation = CONFIG.PingCompensation, ManualPingMs = CONFIG.ManualPingMs,
            BlockLead = CONFIG.BlockLead, DodgeLead = CONFIG.DodgeLead, DodgeCooldown = CONFIG.DodgeCooldown,
            DodgeTapDuration = CONFIG.DodgeTapDuration, BlockHoldAfterImpact = CONFIG.BlockHoldAfterImpact,
            ComboGap = CONFIG.ComboGap, LateWindow = CONFIG.LateWindow, MaxBlockCommit = CONFIG.MaxBlockCommit,
            UseKeyframeMarkers = CONFIG.UseKeyframeMarkers, EarlyActionGuard = CONFIG.EarlyActionGuard,
            FilterMode = CONFIG.FilterMode, ImpactRatio = CONFIG.ImpactRatio, InputMode = CONFIG.InputMode,
            InputMethod = CONFIG.InputMethod, WindowTransparency = CONFIG.WindowTransparency, Accent = CONFIG.Accent,
            AnimateHeader = CONFIG.AnimateHeader, LearnedTimings = CONFIG.LearnedTimings,
            AttackWhitelist = CONFIG.AttackWhitelist, LearnDistance = CONFIG.LearnDistance,
            ZeroLengthFallback = CONFIG.ZeroLengthFallback, ZeroLengthHold = CONFIG.ZeroLengthHold,
            MaxTrackAge = CONFIG.MaxTrackAge, PriorityFilter = CONFIG.PriorityFilter,
            UseMovementDirection = CONFIG.UseMovementDirection, MinAttackerSpeed = CONFIG.MinAttackerSpeed,
            VelocityTowardDot = CONFIG.VelocityTowardDot, ThreatGrace = CONFIG.ThreatGrace,
            LearnMode = CONFIG.LearnMode, RecordSelfAnimations = CONFIG.RecordSelfAnimations,
        }
        local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
        if not ok then toast("JSON encode failed", "error"); return end
        local wrote = pcall(writeFn, "Aero_RevengersX_Config.json", encoded)
        if wrote then toast("Config saved") else toast("Config save failed", "error") end
    end)
    addAction(settings, "Load config (JSON)", function()
        local readFn, isfileFn = capability("readfile"), capability("isfile")
        if type(readFn) ~= "function" or not HttpService then toast("readfile unavailable", "error"); return end
        if type(isfileFn) == "function" then
            local ok, exists = pcall(isfileFn, "Aero_RevengersX_Config.json")
            if not ok or not exists then toast("Config file not found", "error"); return end
        end
        local okRead, raw = pcall(readFn, "Aero_RevengersX_Config.json")
        if not okRead or type(raw) ~= "string" then toast("Config read failed", "error"); return end
        local okDecode, data = pcall(function() return HttpService:JSONDecode(raw) end)
        if not okDecode or type(data) ~= "table" then toast("Invalid config JSON", "error"); return end
        local allowed = {
            "MenuKey", "BlockKey", "DodgeKey", "AutoBlock", "AutoDodge", "ResponseMode", "IgnoreSameTeam", "FacingCheck", "FacingDot",
            "MaxDistance", "PingCompensation", "ManualPingMs", "BlockLead", "DodgeLead", "DodgeCooldown", "DodgeTapDuration",
            "BlockHoldAfterImpact", "ComboGap", "LateWindow", "FilterMode", "ImpactRatio", "MaxBlockCommit", "UseKeyframeMarkers",
            "EarlyActionGuard", "InputMode", "InputMethod", "WindowTransparency", "Accent", "AnimateHeader", "LearnedTimings",
            "AttackWhitelist", "LearnDistance", "ZeroLengthFallback", "ZeroLengthHold", "MaxTrackAge", "PriorityFilter",
            "UseMovementDirection", "MinAttackerSpeed", "VelocityTowardDot", "ThreatGrace",
        }
        for _, key in ipairs(allowed) do
            local value = data[key]
            if value ~= nil and type(value) == type(DEFAULTS[key]) then CONFIG[key] = value end
        end
        if type(CONFIG.Accent) ~= "table" or #CONFIG.Accent < 3 then CONFIG.Accent = { 220, 231, 255 } end
        if CONFIG.FilterMode ~= "ThreatCandidate" and CONFIG.FilterMode ~= "NonLooped" and CONFIG.FilterMode ~= "All" and CONFIG.FilterMode ~= "Whitelist" then CONFIG.FilterMode = "ThreatCandidate" end
        if CONFIG.InputMode ~= "Auto" and CONFIG.InputMode ~= "Key" and CONFIG.InputMode ~= "Remote" then CONFIG.InputMode = "Auto" end
        if CONFIG.InputMethod ~= "VIM" and CONFIG.InputMethod ~= "keypress" and CONFIG.InputMethod ~= "both" then CONFIG.InputMethod = "VIM" end
        if not getKeyCode(CONFIG.MenuKey) then CONFIG.MenuKey = DEFAULTS.MenuKey end
        if not getKeyCode(CONFIG.BlockKey) then CONFIG.BlockKey = DEFAULTS.BlockKey end
        if not getKeyCode(CONFIG.DodgeKey) then CONFIG.DodgeKey = DEFAULTS.DodgeKey end
        CONFIG.MaxDistance = clamp(tonumber(CONFIG.MaxDistance) or 34, 5, 100)
        CONFIG.FacingDot = clamp(tonumber(CONFIG.FacingDot) or 0.05, -1, 1)
        CONFIG.VelocityTowardDot = clamp(tonumber(CONFIG.VelocityTowardDot) or 0.35, -1, 1)
        CONFIG.MinAttackerSpeed = clamp(tonumber(CONFIG.MinAttackerSpeed) or 2.25, 0, 30)
        CONFIG.ThreatGrace = clamp(tonumber(CONFIG.ThreatGrace) or 0.10, 0, 0.50)
        CONFIG.BlockLead = clamp(tonumber(CONFIG.BlockLead) or 0.22, 0.01, 1)
        CONFIG.DodgeLead = clamp(tonumber(CONFIG.DodgeLead) or 0.12, 0.01, 1)
        CONFIG.DodgeCooldown = clamp(tonumber(CONFIG.DodgeCooldown) or 1.1, 0.1, 10)
        CONFIG.DodgeTapDuration = clamp(tonumber(CONFIG.DodgeTapDuration) or 0.12, 0.03, 1)
        CONFIG.ComboGap = clamp(tonumber(CONFIG.ComboGap) or 0.42, 0, 2)
        CONFIG.MaxBlockCommit = clamp(tonumber(CONFIG.MaxBlockCommit) or 1.35, 0.1, 5)
        CONFIG.ImpactRatio = clamp(tonumber(CONFIG.ImpactRatio) or 0.72, 0.05, 1)
        CONFIG.LearnDistance = clamp(tonumber(CONFIG.LearnDistance) or 22, 5, 100)
        if CONFIG.ResponseMode ~= "Immediate" and CONFIG.ResponseMode ~= "Timed" then CONFIG.ResponseMode = "Immediate" end
        CONFIG.ZeroLengthHold = clamp(tonumber(CONFIG.ZeroLengthHold) or 0.24, 0.05, 1)
        CONFIG.MaxTrackAge = clamp(tonumber(CONFIG.MaxTrackAge) or 2.25, 0.1, 10)
        CONFIG.WindowTransparency = clamp(tonumber(CONFIG.WindowTransparency) or 0.08, 0, 0.8)
        for _, refresh in pairs(UIRefs.Refreshers or {}) do pcall(refresh) end
        if UIRefs.BindButtons then
            for key, button in pairs(UIRefs.BindButtons) do pcall(function() button.Text = CONFIG[key] end) end
        end
        applyTheme()
        toast("Config loaded")
    end)
    addAction(settings, "Unload script", function()
        if type(_G.AERO_REVENGERS_UNLOAD) == "function" then _G.AERO_REVENGERS_UNLOAD() end
    end)

    -- Theme tab
    pageSection(theme, "Accent presets")
    local presetRow = pageRow(theme, 42)
    local presets = {
        { "Silver", { 220, 231, 255 } },
        { "Ice", { 164, 179, 218 } },
        { "Lilac", { 194, 168, 220 } },
        { "Steel", { 133, 166, 195 } },
    }
    for i, preset in ipairs(presets) do
        local button = makeButton(presetRow, preset[1], function()
            CONFIG.Accent = { preset[2][1], preset[2][2], preset[2][3] }
            applyTheme()
            toast("Accent: " .. preset[1])
        end, 52)
        button.Position = UDim2.new(0, 7 + (i - 1) * 55, 0.5, -14)
        button.Size = UDim2.fromOffset(51, 28)
    end
    pageSection(theme, "Custom color / window")
    local hexRow = pageRow(theme, 42)
    local hexLabel = makeLabel(hexRow, "HEX", 10, COLORS.Muted, Enum.Font.GothamBold)
    hexLabel.Position = UDim2.new(0, 9, 0, 0)
    hexLabel.Size = UDim2.new(0, 34, 1, 0)
    local hexBox = create("TextBox", {
        BackgroundColor3 = COLORS.Panel2,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        PlaceholderText = "#DCE7FF",
        Text = "",
        TextColor3 = COLORS.Text,
        PlaceholderColor3 = COLORS.Muted,
        TextSize = 11,
        Font = Enum.Font.Gotham,
        Position = UDim2.new(0, 48, 0, 6),
        Size = UDim2.new(1, -56, 0, 29),
    }, hexRow)
    corner(hexBox, 6)
    connect(hexBox.FocusLost, function(enterPressed)
        if not enterPressed then return end
        local hex = string.gsub(hexBox.Text, "#", "")
        if #hex == 6 and string.match(hex, "^%x%x%x%x%x%x$") then
            CONFIG.Accent = {
                tonumber(string.sub(hex, 1, 2), 16),
                tonumber(string.sub(hex, 3, 4), 16),
                tonumber(string.sub(hex, 5, 6), 16),
            }
            applyTheme()
            toast("Custom accent applied")
        else
            toast("Enter a 6-digit HEX color", "error")
        end
    end)
    addToggle(theme, "Animated gradient / shimmer", "AnimateHeader")
    addSlider(theme, "Window transparency", "WindowTransparency", 0, 0.35, 2, function() applyTheme() end)

    setTab("Combat")
    applyTheme()

    connect(Header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            State.DraggingWindow = true
            State.WindowDragStart = input.Position
            State.WindowStartPosition = Main.Position
        end
    end)

    State.MenuOpen = true
    toast("Aero loaded  •  RightShift to toggle")
end
--==============================================================
-- WindUI menu adapter (Aero tabs and controls)
-- WindUI is pinned to a reviewed commit instead of tracking main.
--==============================================================
local AeroWindow
local AeroWindUI

local function aeroNotify(title, content, icon)
    if AeroWindUI then
        pcall(function()
            AeroWindUI:Notify({ Title = title, Content = content, Icon = icon or "info", Duration = 3 })
        end)
    else
        toast(title .. ": " .. content)
    end
end

local function saveAeroConfig()
    local writeFn = capability("writefile")
    if type(writeFn) ~= "function" or not HttpService then
        aeroNotify("Config", "writefile unavailable", "alert-circle")
        return
    end
    local keys = {
        "Version", "MenuKey", "BlockKey", "DodgeKey", "AutoBlock", "AutoDodge", "ResponseMode",
        "IgnoreSameTeam", "FacingCheck", "FacingDot", "MaxDistance", "PingCompensation", "ManualPingMs",
        "BlockLead", "DodgeLead", "DodgeCooldown", "DodgeTapDuration", "BlockHoldAfterImpact", "ComboGap",
        "LateWindow", "MaxBlockCommit", "UseKeyframeMarkers", "EarlyActionGuard", "FilterMode", "ImpactRatio",
        "InputMode", "InputMethod", "WindowTransparency", "Accent", "AnimateHeader", "LearnedTimings",
        "AttackWhitelist", "LearnDistance", "ZeroLengthFallback", "ZeroLengthHold", "MaxTrackAge",
        "PriorityFilter", "UseMovementDirection", "MinAttackerSpeed", "VelocityTowardDot", "ThreatGrace",
        "RecoveryEnabled", "RecoveryWindow", "RecoveryBlockHold", "LearnMode", "RecordSelfAnimations"
    }
    local data = {}
    for _, key in ipairs(keys) do data[key] = CONFIG[key] end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if not ok then aeroNotify("Config", "JSON encode failed", "alert-circle"); return end
    local wrote = pcall(writeFn, "Aero_RevengersX_Config.json", encoded)
    aeroNotify("Config", wrote and "Saved Aero_RevengersX_Config.json" or "Save failed", wrote and "check" or "alert-circle")
end

local function loadAeroConfig()
    local readFn, isfileFn = capability("readfile"), capability("isfile")
    if type(readFn) ~= "function" or not HttpService then
        aeroNotify("Config", "readfile unavailable", "alert-circle")
        return
    end
    if type(isfileFn) == "function" then
        local ok, exists = pcall(isfileFn, "Aero_RevengersX_Config.json")
        if not ok or not exists then aeroNotify("Config", "Config file not found", "alert-circle"); return end
    end
    local okRead, raw = pcall(readFn, "Aero_RevengersX_Config.json")
    if not okRead or type(raw) ~= "string" then aeroNotify("Config", "Read failed", "alert-circle"); return end
    local okDecode, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not okDecode or type(data) ~= "table" then aeroNotify("Config", "Invalid JSON", "alert-circle"); return end
    for key, value in pairs(data) do
        if key ~= "RemoteAdapter" and DEFAULTS[key] ~= nil and type(value) == type(DEFAULTS[key]) then
            CONFIG[key] = value
        end
    end
    CONFIG.MaxDistance = clamp(tonumber(CONFIG.MaxDistance) or 34, 5, 100)
    CONFIG.FacingDot = clamp(tonumber(CONFIG.FacingDot) or 0.05, -1, 1)
    CONFIG.VelocityTowardDot = clamp(tonumber(CONFIG.VelocityTowardDot) or 0.35, -1, 1)
    if not getKeyCode(CONFIG.MenuKey) then CONFIG.MenuKey = DEFAULTS.MenuKey end
    if not getKeyCode(CONFIG.BlockKey) then CONFIG.BlockKey = DEFAULTS.BlockKey end
    if not getKeyCode(CONFIG.DodgeKey) then CONFIG.DodgeKey = DEFAULTS.DodgeKey end
    aeroNotify("Config", "Loaded. Reopen menu if a control does not refresh.", "check")
end

local function sanitizeProfileName(name)
    name = tostring(name or "Default")
    name = string.gsub(name, "[^%w_%-]", "_")
    name = string.sub(name, 1, 32)
    if name == "" then name = "Default" end
    return name
end

local function profilePath(name)
    return "Aero_RevengersX/Profiles/" .. sanitizeProfileName(name) .. ".json"
end

local function ensureProfileFolders()
    local makeFolder = capability("makefolder")
    if type(makeFolder) == "function" then
        pcall(makeFolder, "Aero_RevengersX")
        pcall(makeFolder, "Aero_RevengersX/Profiles")
    end
end

local function getConfigSnapshot()
    local keys = {
        "Version", "MenuKey", "BlockKey", "DodgeKey", "AutoBlock", "AutoDodge", "ResponseMode",
        "IgnoreSameTeam", "FacingCheck", "FacingDot", "MaxDistance", "PingCompensation", "ManualPingMs",
        "BlockLead", "DodgeLead", "DodgeCooldown", "DodgeTapDuration", "BlockHoldAfterImpact", "ComboGap",
        "LateWindow", "MaxBlockCommit", "UseKeyframeMarkers", "EarlyActionGuard", "FilterMode", "ImpactRatio",
        "InputMode", "InputMethod", "WindowTransparency", "Accent", "AnimateHeader", "LearnedTimings",
        "AttackWhitelist", "LearnDistance", "ZeroLengthFallback", "ZeroLengthHold", "MaxTrackAge",
        "PriorityFilter", "UseMovementDirection", "MinAttackerSpeed", "VelocityTowardDot", "ThreatGrace",
        "RecoveryEnabled", "RecoveryWindow", "RecoveryBlockHold", "LearnMode", "RecordSelfAnimations"
    }
    local data = {}
    for _, key in ipairs(keys) do data[key] = CONFIG[key] end
    return data
end

local function saveNamedProfile(name)
    local writeFn = capability("writefile")
    if type(writeFn) ~= "function" or not HttpService then
        aeroNotify("Profiles", "Executor file API unavailable", "alert-circle")
        return
    end
    ensureProfileFolders()
    local path = profilePath(name)
    local okEncode, encoded = pcall(function() return HttpService:JSONEncode(getConfigSnapshot()) end)
    if not okEncode then aeroNotify("Profiles", "JSON encode failed", "alert-circle"); return end
    local okWrite = pcall(writeFn, path, encoded)
    aeroNotify("Profiles", okWrite and ("Saved " .. sanitizeProfileName(name)) or "Save failed", okWrite and "check" or "alert-circle")
end

local function loadNamedProfile(name)
    local readFn, isfileFn = capability("readfile"), capability("isfile")
    if type(readFn) ~= "function" or not HttpService then
        aeroNotify("Profiles", "Executor file API unavailable", "alert-circle")
        return
    end
    local path = profilePath(name)
    if type(isfileFn) == "function" then
        local okExists, exists = pcall(isfileFn, path)
        if not okExists or not exists then aeroNotify("Profiles", "Profile not found: " .. sanitizeProfileName(name), "alert-circle"); return end
    end
    local okRead, raw = pcall(readFn, path)
    if not okRead or type(raw) ~= "string" then aeroNotify("Profiles", "Profile read failed", "alert-circle"); return end
    local okDecode, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not okDecode or type(data) ~= "table" then aeroNotify("Profiles", "Profile JSON is invalid", "alert-circle"); return end
    for key, value in pairs(data) do
        if key ~= "RemoteAdapter" and DEFAULTS[key] ~= nil and type(value) == type(DEFAULTS[key]) then
            CONFIG[key] = value
        end
    end
    CONFIG.MaxDistance = clamp(tonumber(CONFIG.MaxDistance) or 34, 5, 100)
    CONFIG.DodgeCooldown = clamp(tonumber(CONFIG.DodgeCooldown) or 1.1, 0.1, 10)
    DodgeCooldownGate.Duration = CONFIG.DodgeCooldown
    DodgeCooldownGate:Reset()
    aeroNotify("Profiles", "Loaded " .. sanitizeProfileName(name) .. " — restart script to refresh all controls", "check")
end

local function printDebugSnapshot()
    local d = State.Diagnostics
    local remaining = DodgeCooldownGate:Remaining()
    print(string.format(
        "[Aero Monitor] uptime=%.1fs | animators=%d | seen=%d | accepted=%d | rejected=%d | blocks=%d | target=%s | distance=%.1f | marker=%s | dodgeCD=%.2fs | reject=%s",
        os.clock() - State.StartedAt, d.AnimatorsBound, d.TracksSeen, d.TracksAccepted, d.TracksRejected,
        d.BlockRequests, tostring(d.LastTarget), tonumber(d.LastDistance) or 0, tostring(State.LastMarker),
        remaining, tostring(d.LastReject)
    ))
    aeroNotify("Combat Monitor", "Snapshot printed to F9 console", "activity")
end

local function printRecentDebug()
    print("[Aero Debug Console] ---- recent events ----")
    local first = math.max(1, #State.DebugEntries - 24)
    for i = first, #State.DebugEntries do print(State.DebugEntries[i]) end
    print("[Aero Debug Console] ---- end ----")
    aeroNotify("Debug Console", "Recent events printed to F9", "terminal")
end

local function windToggle(tab, title, key, desc)
    return tab:Toggle({
        Title = title, Desc = desc, Value = CONFIG[key] == true,
        Callback = function(value)
            CONFIG[key] = value == true
            if key == "LearnMode" then
                aeroNotify("Learn Mode", value and "Enabled — inspect F9 console" or "Stopped", "brain")
            elseif key == "AnimateHeader" then
                CONFIG.AnimateHeader = value == true
            end
        end,
    })
end

local function windSlider(tab, title, key, minimum, maximum, step, desc)
    return tab:Slider({
        Title = title, Desc = desc, Step = step,
        Value = { Min = minimum, Max = maximum, Default = tonumber(CONFIG[key]) or minimum },
        Callback = function(value) CONFIG[key] = tonumber(value) or CONFIG[key] end,
    })
end

local function windCycle(tab, title, key, values, desc)
    return tab:Dropdown({
        Title = title, Desc = desc, Values = values, Value = CONFIG[key], AllowNone = false,
        Callback = function(value)
            if type(value) == "string" then CONFIG[key] = value end
        end,
    })
end

local function makeWindUI()
    local ok, result = pcall(function()
        local source = "https://raw.githubusercontent.com/Footagesus/WindUI/d2c9bac5f96f997418d680d19cb759892542e492/dist/main.lua"
        return loadstring(game:HttpGet(source))()
    end)
    if not ok or not result then
        notifyWarn("WindUI failed to load; falling back to the built-in Aero menu. " .. tostring(result))
        makeUI()
        return
    end
    AeroWindUI = result

    AeroWindow = AeroWindUI:CreateWindow({
        Title = "AERO  |  REVENGERS X",
        Icon = "solar:shield-check-bold",
        Theme = "Dark",
        Folder = "Aero_RevengersX",
        NewElements = true,
        HideSearchBar = false,
        Topbar = { Height = 44, ButtonsType = "Mac" },
        OpenButton = {
            Title = "Open AERO",
            Enabled = true,
            Draggable = true,
            OnlyMobile = false,
            CornerRadius = UDim.new(1, 0),
        },
    })
    if not AeroWindow then notifyWarn("WindUI window creation failed"); return end
    pcall(function() AeroWindow:Tag({ Title = "AERO V7", Icon = "github", Color = Color3.fromHex("#7775F2"), Border = true }) end)

    local combat = AeroWindow:Tab({ Title = "Combat", Icon = "solar:shield-bold", Border = true })
    local settings = AeroWindow:Tab({ Title = "Settings", Icon = "solar:settings-bold", Border = true })
    local theme = AeroWindow:Tab({ Title = "Theme", Icon = "solar:palette-bold", Border = true })

    combat:Section({ Title = "Defense" })
    windToggle(combat, "Auto Block", "AutoBlock", "Automatically request block when a threat candidate is confirmed")
    combat:Keybind({ Title = "Block key", Value = CONFIG.BlockKey, Callback = function(value)
        if type(value) == "string" then CONFIG.BlockKey = value end
    end })
    windToggle(combat, "Auto Dodge", "AutoDodge", "Optional dodge response; disabled by default")
    combat:Keybind({ Title = "Dodge key", Value = CONFIG.DodgeKey, Callback = function(value)
        if type(value) == "string" then CONFIG.DodgeKey = value end
    end })
    windCycle(combat, "Response mode", "ResponseMode", { "Immediate", "Timed" })
    windToggle(combat, "Require attack aimed at me", "FacingCheck")
    windToggle(combat, "Ignore same Roblox Team", "IgnoreSameTeam")
    windToggle(combat, "Ping compensation", "PingCompensation")
    windToggle(combat, "Post-hit recovery", "RecoveryEnabled")

    combat:Section({ Title = "Detection" })
    windSlider(combat, "Max threat distance", "MaxDistance", 5, 40, 1)
    windSlider(combat, "Block lead (sec)", "BlockLead", 0.05, 0.60, 0.01)
    windSlider(combat, "Facing threshold", "FacingDot", -0.35, 0.9, 0.01)
    windSlider(combat, "Move-toward threshold", "VelocityTowardDot", -0.25, 0.95, 0.01)
    windSlider(combat, "Minimum attacker speed", "MinAttackerSpeed", 0.5, 12, 0.1)
    windSlider(combat, "Learn distance", "LearnDistance", 5, 35, 1)
    windToggle(combat, "Zero-length fallback", "ZeroLengthFallback")
    windToggle(combat, "Use named hit keyframes", "UseKeyframeMarkers")
    windToggle(combat, "Early guard on Action animations", "EarlyActionGuard")
    windCycle(combat, "Animation filter", "FilterMode", { "ThreatCandidate", "NonLooped", "All", "Whitelist" })
    combat:Input({ Title = "Animation whitelist IDs", Desc = "Comma-separated numeric or asset IDs", Value = table.concat(CONFIG.AttackWhitelist or {}, ","), Placeholder = "12345, 67890", Callback = function(value)
        local ids = {}
        for token in string.gmatch(tostring(value or ""), "[^,]+") do
            local id = string.gsub(token, "%s+", "")
            if id ~= "" then table.insert(ids, id) end
        end
        CONFIG.AttackWhitelist = ids
    end })

    combat:Section({ Title = "Learning and diagnostics" })
    windToggle(combat, "Record my animations", "RecordSelfAnimations", "Prints Animation IDs from your own character only")
    windToggle(combat, "Learn Mode", "LearnMode", "Correlates nearby opponent tracks with your health loss")
    combat:Button({ Title = "Test block input", Icon = "shield", Callback = function()
        local sent = pulseAction("Block", CONFIG.BlockKey, 0.16)
        aeroNotify("Input test", sent and "Block input sent" or "Block input unavailable", sent and "check" or "alert-circle")
    end })
    combat:Button({ Title = "Test dodge input", Icon = "move-right", Callback = function()
        local sent = pulseAction("Dodge", CONFIG.DodgeKey, CONFIG.DodgeTapDuration)
        aeroNotify("Input test", sent and "Dodge input sent" or "Dodge input unavailable", sent and "check" or "alert-circle")
    end })
    combat:Button({ Title = "Reset learned timings", Icon = "refresh-ccw", Callback = function()
        CONFIG.LearnedTimings = {}; State.LastLearnLog = {}
        aeroNotify("Learn Mode", "Learned timing estimates cleared", "check")
    end })
    combat:Button({ Title = "Print combat diagnostics", Icon = "terminal", Callback = function()
        local d = State.Diagnostics
        print(string.format("[Aero Status] animators=%d tracksSeen=%d tracksAccepted=%d tracksRejected=%d blockRequests=%d target=%s distance=%.1f facing=%.2f velocity=%.2f lastReject=%s lastBlock=%s",
            d.AnimatorsBound, d.TracksSeen, d.TracksAccepted, d.TracksRejected, d.BlockRequests,
            tostring(d.LastTarget), tonumber(d.LastDistance) or 0, tonumber(d.LastFacingDot) or -1,
            tonumber(d.LastVelocityDot) or -1, tostring(d.LastReject), tostring(d.LastBlockReason)))
        aeroNotify("Diagnostics", "Printed to F9 console", "terminal")
    end })

    combat:Section({ Title = "Animation markers / debug console" })
    combat:Paragraph({ Title = "Marker observer", Desc = "Listens for common marker names (Hit, Impact, Damage, Strike, Hitbox, Attack). Marker events are diagnostic only; they are not verified hitboxes." })
    combat:Button({ Title = "Live monitor snapshot", Icon = "activity", Callback = printDebugSnapshot })
    combat:Button({ Title = "Print recent debug events", Icon = "terminal", Callback = printRecentDebug })
    combat:Button({ Title = "Clear debug events", Icon = "trash-2", Callback = function()
        State.DebugEntries = {}
        aeroNotify("Debug Console", "Event buffer cleared", "check")
    end })

    settings:Section({ Title = "Input backend" })
    windCycle(settings, "Input mode", "InputMode", { "Auto", "Key", "Remote" })
    windCycle(settings, "Key sender", "InputMethod", { "VIM", "keypress", "both" })
    settings:Keybind({ Title = "Menu hotkey", Value = CONFIG.MenuKey, Callback = function(value)
        if type(value) == "string" then
            CONFIG.MenuKey = value
            local enum = getKeyCode(value)
            if enum then pcall(function() AeroWindow:SetToggleKey(enum) end) end
        end
    end })
    settings:Section({ Title = "Reliability" })
    windSlider(settings, "Dodge cooldown (sec)", "DodgeCooldown", 0.25, 3, 0.01)
    windSlider(settings, "Dodge tap (sec)", "DodgeTapDuration", 0.05, 0.30, 0.01)
    windSlider(settings, "Combo gap (sec)", "ComboGap", 0.05, 0.80, 0.01)
    windSlider(settings, "Max block commitment (sec)", "MaxBlockCommit", 0.20, 2.50, 0.01)
    windSlider(settings, "Manual ping fallback (ms)", "ManualPingMs", 0, 300, 1)
    settings:Button({ Title = "Save config (JSON)", Icon = "save", Callback = saveAeroConfig })
    settings:Button({ Title = "Load config (JSON)", Icon = "folder-open", Callback = loadAeroConfig })
    local selectedProfile = "Default"
    settings:Section({ Title = "Config Manager — named profiles" })
    settings:Input({ Title = "Profile name", Desc = "Letters, numbers, underscore and dash are retained", Value = selectedProfile, Placeholder = "Default", Callback = function(value)
        selectedProfile = sanitizeProfileName(value)
    end })
    settings:Button({ Title = "Save named profile", Icon = "save", Callback = function()
        saveNamedProfile(selectedProfile)
    end })
    settings:Button({ Title = "Load named profile", Icon = "folder-open", Callback = function()
        loadNamedProfile(selectedProfile)
    end })
    settings:Button({ Title = "Unload script", Icon = "power", Color = Color3.fromHex("#D94A5A"), Callback = function()
        if type(_G.AERO_REVENGERS_UNLOAD) == "function" then _G.AERO_REVENGERS_UNLOAD() end
    end })

    theme:Section({ Title = "Appearance" })
    theme:Paragraph({ Title = "WindUI Dark", Desc = "Aero uses the WindUI dark interface theme. The original Combat, Settings and Theme groups are preserved as tabs." })
    windToggle(theme, "Animated header preference", "AnimateHeader", "Retained in Aero config; WindUI controls its own window animation")
    windSlider(theme, "Saved transparency preference", "WindowTransparency", 0, 0.35, 0.01, "Stored in config for compatibility with Aero settings")
    theme:Button({ Title = "Silver preset", Icon = "palette", Callback = function()
        CONFIG.Accent = { 220, 231, 255 }; aeroNotify("Theme", "Silver preset saved", "check")
    end })
    theme:Button({ Title = "Lilac preset", Icon = "palette", Callback = function()
        CONFIG.Accent = { 194, 168, 220 }; aeroNotify("Theme", "Lilac preset saved", "check")
    end })
    theme:Button({ Title = "Ice preset", Icon = "palette", Callback = function()
        CONFIG.Accent = { 164, 179, 218 }; aeroNotify("Theme", "Ice preset saved", "check")
    end })

    pcall(function()
        local menuKey = getKeyCode(CONFIG.MenuKey)
        if menuKey then AeroWindow:SetToggleKey(menuKey) end
    end)
    aeroNotify("AERO", "WindUI menu loaded", "check")
end

--==============================================================
-- Lifecycle / config callbacks / input events
--==============================================================

local function unload()
    if State.Unloaded then return end
    State.Unloaded = true

    releaseAllInputs()
    State.ActiveTracks = {}
    State.WatchedAnimators = {}

    for _, bucket in pairs(State.CharacterConnections) do
        for _, connection in ipairs(bucket) do pcall(function() connection:Disconnect() end) end
    end
    for _, bucket in pairs(State.PlayerConnections) do
        for _, connection in ipairs(bucket) do pcall(function() connection:Disconnect() end) end
    end
    for _, connection in ipairs(State.LocalCharacterConnections) do
        pcall(function() connection:Disconnect() end)
    end
    for _, connection in ipairs(State.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    for _, thread in ipairs(State.Threads) do
        pcall(function()
            if type(task.cancel) == "function" then task.cancel(thread) end
        end)
    end

    pcall(function() if AeroWindow then AeroWindow:Destroy() end end)
    pcall(function() if GUI then GUI:Destroy() end end)
    pcall(function() _G.AERO_REVENGERS_UNLOAD = nil end)
    notifyWarn("Unloaded; connections cleared and held input released.")
end

_G.AERO_REVENGERS_UNLOAD = unload

connect(Players.PlayerAdded, bindPlayer)
connect(Players.PlayerRemoving, function(player)
    local bucket = State.PlayerConnections[player]
    if bucket then
        for _, connection in ipairs(bucket) do pcall(function() connection:Disconnect() end) end
    end
    State.PlayerConnections[player] = nil
    local characterBucket = State.CharacterConnections[player]
    if characterBucket then
        for _, connection in ipairs(characterBucket) do pcall(function() connection:Disconnect() end) end
    end
    State.CharacterConnections[player] = nil
    for animator, watch in pairs(State.WatchedAnimators) do
        if watch and watch.Player == player then
            State.WatchedAnimators[animator] = nil
            State.Diagnostics.AnimatorsBound = math.max(0, State.Diagnostics.AnimatorsBound - 1)
        end
    end
    for i = #State.ActiveTracks, 1, -1 do
        if State.ActiveTracks[i].Player == player then table.remove(State.ActiveTracks, i) end
    end
end)

--==============================================================
-- V9 NPC animation observer / damage-correlated learning
-- Scans Workspace NPC models (not only Players). Damage correlation is heuristic.
--==============================================================
local NpcObservedAnimators = setmetatable({}, { __mode = "k" })
local NpcObservedModels = setmetatable({}, { __mode = "k" })
local NpcLearnedIds = {}
local NpcLastDamageScan = 0

local function npcRoot(model)
    if not model then return nil end
    return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
        or model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
end

local function npcDistance(model)
    local _, _, localRoot = getCharacterParts(LocalPlayer)
    local root = npcRoot(model)
    if not localRoot or not root then return math.huge end
    local ok, value = pcall(function() return (localRoot.Position-root.Position).Magnitude end)
    return ok and value or math.huge
end

local function logNpcTrack(model, track, reason)
    local animationId, length, position, speed, weight = "unknown", 0, 0, 1, 0
    pcall(function()
        local animation = track.Animation
        animationId = animation and animation.AnimationId or "unknown"
        length = track.Length
        position = track.TimePosition
        speed = track.Speed
        weight = track.WeightCurrent
    end)
    local distance = npcDistance(model)
    State.Diagnostics.NpcTracksSeen += 1
    print(string.format("[Aero V10 DAMAGE] %s | npc=%s | id=%s | distance=%.2f | position=%.3f | length=%.3f | speed=%.2f | weight=%.2f",
        tostring(reason), model:GetFullName(), tostring(animationId), distance,
        tonumber(position) or 0, tonumber(length) or 0, tonumber(speed) or 1, tonumber(weight) or 0))
    return tostring(animationId), distance
end

local function observeNpcAnimator(model, animator)
    if not animator or NpcObservedAnimators[animator] then return end
    local ok, isAnimator = pcall(function() return animator:IsA("Animator") end)
    if not ok or not isAnimator then return end
    NpcObservedAnimators[animator] = model
    State.Diagnostics.NpcAnimatorsBound += 1
    -- NPC animator binding is intentionally silent; output is reserved for local damage snapshots.

    local function onPlayed(track)
        local id = "unknown"
        pcall(function()
            local animation = track.Animation
            id = animation and animation.AnimationId or "unknown"
        end)
        id = tostring(id or "unknown")
        local distance = npcDistance(model)
        -- Do not print every NPC animation. Only a previously damage-correlated ID
        -- can trigger a short diagnostic and the optional block response.
        if NpcLearnedIds[id] and distance <= CONFIG.NpcScanRadius then
            print(string.format("[Aero V10 NPC] learned candidate replay | npc=%s | id=%s | distance=%.2f",
                model:GetFullName(), id, distance))
            if CONFIG.AutoBlock then
                local now = os.clock()
                requestBlock(now + math.max(CONFIG.BlockHoldAfterImpact, 0.16), now, "learned NPC animation " .. id)
                setActionHeld("Block", CONFIG.BlockKey, true)
            end
        end
    end
    connect(animator.AnimationPlayed, onPlayed)
    local playing = {}
    pcall(function() playing = animator:GetPlayingAnimationTracks() end)
    for _, track in ipairs(playing) do onPlayed(track) end
end

local function observeNpcModel(model)
    if not model or NpcObservedModels[model] then return end
    if not model:IsA("Model") or Players:GetPlayerFromCharacter(model) then return end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    NpcObservedModels[model] = true
    local function inspect(descendant)
        if descendant:IsA("Animator") then observeNpcAnimator(model, descendant) end
    end
    for _, descendant in ipairs(model:GetDescendants()) do inspect(descendant) end
    connect(model.DescendantAdded, inspect)
end

-- The training NPC's attack usually reduces the LOCAL character health, not the NPC health.
-- Observe the local health signal and snapshot every nearby NPC Animator at that moment.
local function bindLocalDamageScanner(character)
    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 8)
        if not humanoid or State.Unloaded then return end
        local previous = humanoid.Health
        connect(humanoid.HealthChanged, function(health)
            if type(health) ~= "number" then return end
            local tookDamage = health < previous
            previous = health
            if not tookDamage then return end
            print(string.format("[Aero V10 DAMAGE] local health decreased to %.2f | sampling NPC animations within %.1f studs (correlation, not proof)", health, CONFIG.NpcScanRadius))
            local reportedThisHit = {}
            for _, delayTime in ipairs({0, 0.08, 0.18, 0.32}) do
                task.delay(delayTime, function()
                    if State.Unloaded then return end
                    for model in pairs(NpcObservedModels) do
                        if model and model.Parent and npcDistance(model) <= CONFIG.NpcScanRadius then
                            for animator, owner in pairs(NpcObservedAnimators) do
                                if owner == model and animator.Parent then
                                    local active = {}
                                    pcall(function() active = animator:GetPlayingAnimationTracks() end)
                                    for _, track in ipairs(active) do
                                        local id = "unknown"
                                        pcall(function()
                                            local animation = track.Animation
                                            id = animation and animation.AnimationId or "unknown"
                                        end)
                                        id = tostring(id or "unknown")
                                        local distance = npcDistance(model)
                                        local reportKey = model:GetFullName() .. "|" .. id
                                        if distance <= CONFIG.NpcScanRadius and id ~= "unknown" and not reportedThisHit[reportKey] then
                                            reportedThisHit[reportKey] = true
                                            logNpcTrack(model, track, "LOCAL_DAMAGE_CORRELATED")
                                            NpcLearnedIds[id] = true
                                            print("[Aero V10 DAMAGE] candidate animation (not confirmed hitbox): " .. id)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end)
            end
        end)
    end)
end

-- Initial scan plus future NPC spawns.
for _, instance in ipairs(workspace:GetDescendants()) do
    if instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid") then
        observeNpcModel(instance)
    end
end
if LocalPlayer.Character then bindLocalDamageScanner(LocalPlayer.Character) end
connect(LocalPlayer.CharacterAdded, bindLocalDamageScanner)

connect(workspace.DescendantAdded, function(instance)
    if instance:IsA("Model") then
        task.defer(function() if instance.Parent then observeNpcModel(instance) end end)
    elseif instance:IsA("Humanoid") or instance:IsA("Animator") then
        task.defer(function()
            local model = instance:FindFirstAncestorOfClass("Model")
            if model then observeNpcModel(model) end
        end)
    end
end)

local currentPlayers = {}
pcall(function() currentPlayers = Players:GetPlayers() end)
for _, player in ipairs(currentPlayers) do bindPlayer(player) end
if LocalPlayer.Character then bindLocalCharacter(LocalPlayer.Character) end
connect(LocalPlayer.CharacterAdded, bindLocalCharacter)

connect(UserInputService.InputBegan, function(input, gameProcessed)
    if State.Unloaded then return end

    if State.BindingTarget then
        if input.KeyCode and input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode ~= Enum.KeyCode.Escape then
            local target = State.BindingTarget
            CONFIG[target] = input.KeyCode.Name
            State.BindingTarget = nil
            if UIRefs.BindButtons and UIRefs.BindButtons[target] then
                UIRefs.BindButtons[target].Text = CONFIG[target]
            end
            toast(target .. " bound to " .. CONFIG[target])
        elseif input.KeyCode == Enum.KeyCode.Escape then
            State.BindingTarget = nil
            toast("Key bind cancelled")
        end
        return
    end

    if input.KeyCode and input.KeyCode.Name == CONFIG.MenuKey then
        setMenuVisible(not State.MenuOpen)
    end
end)

connect(UserInputService.InputChanged, function(input)
    if State.Unloaded then return end
    if State.SliderDrag and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        State.SliderDrag.Set(input.Position.X)
    end
    if State.DraggingWindow and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - State.WindowDragStart
        if Main and State.WindowStartPosition then
            Main.Position = UDim2.new(
                State.WindowStartPosition.X.Scale,
                State.WindowStartPosition.X.Offset + delta.X,
                State.WindowStartPosition.Y.Scale,
                State.WindowStartPosition.Y.Offset + delta.Y
            )
        end
    end
end)

connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        State.SliderDrag = nil
        State.DraggingWindow = false
    end
end)

if RunService.Heartbeat then
    connect(RunService.Heartbeat, function()
        local ok, err = pcall(combatStep)
        if not ok then notifyWarn("Combat step recovered from error: " .. tostring(err)) end
    end)
end

makeWindUI()

-- Animated monochrome sheen. This is intentionally subtle and fully stopped by Unload.
if false and (UIRefs.Gradient or UIRefs.Shimmer) then
    local thread = task.spawn(function()
        while not State.Unloaded do
            if CONFIG.AnimateHeader then
                if UIRefs.Shimmer and UIRefs.Shimmer.Parent then
                    pcall(function()
                        UIRefs.Shimmer.Offset = Vector2.new(-1, 0)
                        tween(UIRefs.Shimmer, 1.65, { Offset = Vector2.new(1, 0) }, Enum.EasingStyle.Linear)
                    end)
                end
                if UIRefs.Gradient and UIRefs.Gradient.Parent then
                    pcall(function()
                        UIRefs.Gradient.Offset = Vector2.new(-0.55, 0)
                        tween(UIRefs.Gradient, 2.0, { Offset = Vector2.new(0.55, 0) }, Enum.EasingStyle.Sine)
                    end)
                end
                if UIRefs.BorderGradient and UIRefs.BorderGradient.Parent then
                    pcall(function()
                        local nextRotation = UIRefs.BorderGradient.Rotation + 180
                        if nextRotation >= 360 then nextRotation = nextRotation - 360 end
                        tween(UIRefs.BorderGradient, 3.2, { Rotation = nextRotation }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
                    end)
                end
                task.wait(2.05)
            else
                task.wait(0.25)
            end
        end
    end)
    addThread(thread)
end

print("[Aero] Revengers X toolkit V8 initialized. Default response: target-directed Immediate block; Auto Dodge is off by default. RightShift toggles the menu; unload with the UI button or _G.AERO_REVENGERS_UNLOAD().")
