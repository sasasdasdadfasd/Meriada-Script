--[=[
    Revengers X | Aero Combat Toolkit
    Client-side Luau utility for Roblox executors.

    IMPORTANT LIMITATIONS
    - No Revengers X-specific attack IDs, hit markers, attributes or RemoteEvents were supplied.
    - Impact timing prefers common named keyframes when present, then falls back to an animation-ratio estimate.
    - Learn Mode logs nearby tracks and can correlate a recent local health decrease with the closest active attack track.
    - Remote input is supported only through an explicit RemoteAdapter configured below.
    - The default target scanner observes replicated animations on other Players' character Animators; NPCs are not included.
    - If the game does not replicate an opponent's animation to this client, client-side detection cannot see it.

    Recommended: use key input first. Configure exact animation timings only after observing the
    game's animations in Learn mode. This file has not been run inside Roblox or an executor here.
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
    Version = 2,
    MenuKey = "RightShift",
    BlockKey = "F",
    DodgeKey = "Q",

    AutoBlock = true,
    AutoDodge = true,
    FacingCheck = true,
    FacingDot = 0.25,              -- 0.25 ~= within about 75 degrees
    MaxDistance = 18,
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

    FilterMode = "NonLooped",      -- "NonLooped" or "Whitelist"
    AttackWhitelist = {},           -- add exact AnimationId strings here for Whitelist mode
    ImpactRatio = 0.72,              -- fallback estimated impact point; not a verified game marker
    LearnedTimings = {},             -- optional damage-correlated timing estimates; verify before relying on them
    LearnMode = false,

    InputMode = "Auto",             -- "Auto", "Key", "Remote"
    InputMethod = "VIM",            -- "VIM", "keypress", "both"
    -- Optional, user-supplied adapter. Do NOT guess the game's RemoteEvent path.
    -- Signature: function(actionName, isDown, keyName) -> boolean
    RemoteAdapter = nil,

    WindowTransparency = 0.08,
    Accent = { 242, 244, 248 },
    AnimateHeader = true,

    -- Detection safeguards / diagnostics.
    LearnDistance = 22,
    UseKeyframeMarkers = true,
    EarlyActionGuard = true,
    ZeroLengthFallback = true,
    ZeroLengthHold = 0.24,
    MaxTrackAge = 2.25,
    PriorityFilter = false,
}

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
    KnownTracks = {},
    LastThreatAt = 0,
    LastThreatPlayer = nil,
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

--==============================================================
-- Utility / input core
--==============================================================

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

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

local function requestBlock(untilTime, startAt)
    local now = os.clock()
    if State.BlockWantedUntil < now then
        State.BlockStartAt = startAt or now
    elseif startAt and (State.BlockStartAt == 0 or startAt < State.BlockStartAt) then
        State.BlockStartAt = startAt
    end
    State.BlockWantedUntil = math.max(State.BlockWantedUntil, untilTime)
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

local function isTargetEligible(player, attackerHumanoid, attackerRoot)
    if State.Unloaded or not player or player == LocalPlayer then return false end
    if player.Parent ~= Players then return false end

    local localCharacter, localHumanoid, localRoot = getCharacterParts(LocalPlayer)
    if not localCharacter or not localHumanoid or not localRoot then return false end
    if localHumanoid.Health <= 0 then return false end
    if not attackerHumanoid or attackerHumanoid.Health <= 0 or not attackerRoot then return false end

    if player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then
        return false
    end

    local distance = getTargetDistance(attackerRoot)
    if distance > CONFIG.MaxDistance then return false end

    if CONFIG.FacingCheck then
        local ok, dot = pcall(function()
            local direction = (localRoot.Position - attackerRoot.Position).Unit
            return attackerRoot.CFrame.LookVector:Dot(direction)
        end)
        if not ok or dot < CONFIG.FacingDot then return false end
    end

    return true, distance
end

-- Learning uses proximity/alive/team checks but deliberately does not require the attacker
-- to be facing the local character. The combat trigger still honors FacingCheck.
local function isLearnTargetEligible(player, attackerHumanoid, attackerRoot)
    if State.Unloaded or not player or player == LocalPlayer or player.Parent ~= Players then return false end
    local _, localHumanoid, localRoot = getCharacterParts(LocalPlayer)
    if not localHumanoid or localHumanoid.Health <= 0 or not localRoot then return false end
    if not attackerHumanoid or attackerHumanoid.Health <= 0 or not attackerRoot then return false end
    if player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then return false end
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
    State.KnownTracks[track] = true

    local okLooped, looped = pcall(function() return track.Looped end)
    if not okLooped then
        State.KnownTracks[track] = nil
        return
    end
    if CONFIG.FilterMode == "NonLooped" and looped then
        State.KnownTracks[track] = nil
        return
    end

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
        DodgeTriggered = false,
        RecoveryTriggered = false,
        ZeroLengthTriggered = false,
    }
    table.insert(State.ActiveTracks, record)
end

local function bindCharacter(player, character)
    if State.Unloaded or not character then return end
    local previous = State.CharacterConnections[player]
    if previous then
        for _, connection in ipairs(previous) do pcall(function() connection:Disconnect() end) end
    end
    State.CharacterConnections[player] = {}

    local thread = task.spawn(function()
        local humanoid
        local ok = pcall(function()
            humanoid = character:WaitForChild("Humanoid", 6)
        end)
        if not ok or not humanoid or State.Unloaded then return end

        local animator
        pcall(function()
            animator = humanoid:FindFirstChildOfClass("Animator")
            if not animator then animator = humanoid:WaitForChild("Animator", 4) end
        end)
        if not animator or State.Unloaded or player.Character ~= character then return end

        local bucket = State.CharacterConnections[player]
        if not bucket then return end
        connect(animator.AnimationPlayed, function(track)
            registerTrack(player, animator, track)
        end, bucket)

        -- Catch tracks that began just before the connection was installed.
        local playing = {}
        pcall(function() playing = animator:GetPlayingAnimationTracks() end)
        for _, track in ipairs(playing) do
            registerTrack(player, animator, track)
        end
    end)
    addThread(thread)
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

                -- Learn a damage-correlated hit position only when Learn Mode is enabled and
                -- a nearby Action-priority track was observed immediately before the damage.
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
    if now - State.LastDodgeAt < CONFIG.DodgeCooldown then return false end

    -- Avoid overlapping a block and dodge keypress.
    setActionHeld("Block", CONFIG.BlockKey, false)
    local started = setActionHeld("Dodge", CONFIG.DodgeKey, true)
    if not started then return false end

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
    local recovery = isRecovering()
    local pingLead = getPingSeconds()
    local index = 1

    -- If a recent nearby attacker has already damaged us, keep guarding through recovery.
    if recovery and CONFIG.AutoBlock and State.LastThreatAt > 0
        and now - State.LastThreatAt <= CONFIG.RecoveryWindow then
        requestBlock(now + CONFIG.RecoveryBlockHold + CONFIG.ComboGap, now)
    end

    while index <= #State.ActiveTracks do
        local record = State.ActiveTracks[index]
        local track = record.Track
        local keep = false
        local isPlaying, timePosition, speed, loadedLength, currentPriority

        pcall(function()
            isPlaying = track.IsPlaying
            timePosition = track.TimePosition
            speed = track.Speed
            loadedLength = track.Length
            currentPriority = track.Priority
        end)

        if isPlaying then
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
                learnAnimation(record)
            end

            local eligible, distance = isTargetEligible(record.Player, attackerHumanoid, attackerRoot)
            if eligible then
                record.Distance = distance
                record.LastEligibleAt = now
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
                    requestBlock(now + CONFIG.RecoveryBlockHold + CONFIG.ComboGap, now)
                end

                if priorityAccepted and age <= CONFIG.MaxTrackAge then
                    if CONFIG.EarlyActionGuard and actionPriority and CONFIG.AutoBlock
                        and not record.BlockTriggered and record.Length > 0 then
                        local positionNow = math.max(0, tonumber(timePosition) or 0)
                        local remainingNow = clamp((record.Length - positionNow) / safeSpeed, 0, CONFIG.MaxBlockCommit)
                        requestBlock(now + math.max(CONFIG.BlockHoldAfterImpact, remainingNow) + CONFIG.ComboGap, now)
                        record.BlockTriggered = true
                    end

                    if (record.Length <= 0) then
                        -- Roblox reports Length=0 while the animation asset is still loading.
                        -- Use a short immediate guard for any track that passed the selected
                        -- animation filter instead of silently dropping the candidate.
                        if CONFIG.ZeroLengthFallback
                            and not record.ZeroLengthTriggered and CONFIG.AutoBlock then
                            record.ZeroLengthTriggered = true
                            requestBlock(now + CONFIG.ZeroLengthHold + CONFIG.ComboGap, now)
                            record.BlockTriggered = true
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

                        -- Late events are caught immediately while the animation is still active.
                        -- This avoids dropping an attack merely because replication arrived late.
                        if CONFIG.AutoDodge and not record.DodgeTriggered
                            and timeToImpact <= dodgeLead then
                            record.DodgeTriggered = true
                            local dodged = tryDodge(now, impactAt)
                            if not dodged and CONFIG.AutoBlock then
                                requestBlock(blockUntil, now)
                                record.BlockTriggered = true
                            end
                        end

                        if CONFIG.AutoBlock and not record.BlockTriggered
                            and timeToImpact <= blockLead then
                            record.BlockTriggered = true
                            requestBlock(blockUntil, now)
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
end

--==============================================================
-- UI Library (custom monochrome / white-sheen interface)
--==============================================================

local COLORS = {
    Background = Color3.fromRGB(5, 6, 8),
    Panel = Color3.fromRGB(12, 13, 16),
    Panel2 = Color3.fromRGB(20, 21, 25),
    Text = Color3.fromRGB(246, 247, 250),
    Muted = Color3.fromRGB(132, 136, 145),
    Danger = Color3.fromRGB(255, 94, 105),
    White = Color3.fromRGB(255, 255, 255),
    Edge = Color3.fromRGB(68, 71, 80),
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
local UIRefs = { Refreshers = {} }

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
            button.BackgroundColor3 = tabName == State.CurrentTab and accent or COLORS.Panel
            button.TextColor3 = tabName == State.CurrentTab and Color3.fromRGB(5, 6, 8) or COLORS.Muted
            pcall(function() button:SetAttribute("AeroIdleColor", button.BackgroundColor3) end)
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
            ColorSequenceKeypoint.new(0, Color3.fromRGB(31, 32, 37)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(15, 16, 19)),
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
    local holder = create("Frame", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -4, 0, 23),
    }, page)
    local label = makeLabel(holder, string.upper(title), 10, COLORS.White, Enum.Font.GothamBold)
    label.Size = UDim2.new(0, 220, 1, 0)
    local rule = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(53, 55, 61),
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -1),
        Size = UDim2.new(1, 0, 0, 1),
    }, holder)
    return holder
end

local function pageRow(page, height)
    local row = create("Frame", {
        BackgroundColor3 = COLORS.Panel,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -2, 0, height or 42),
    }, page)
    corner(row, 9)
    stroke(row, Color3.fromRGB(42, 44, 50), 0.62)
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
        BackgroundColor3 = Color3.fromRGB(46, 49, 64),
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
    local page = create("ScrollingFrame", {
        Name = name .. "Page",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 1, 0),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Color3.fromRGB(220, 222, 228),
        Visible = false,
    }, Content)
    local layout = create("UIListLayout", {
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, page)
    create("UIPadding", {
        PaddingTop = UDim.new(0, 3),
        PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 2),
        PaddingRight = UDim.new(0, 5),
    }, page)
    connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
        page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 12)
    end)
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
        button.BackgroundColor3 = tabName == name and accentColor() or COLORS.Panel
        button.TextColor3 = tabName == name and Color3.fromRGB(5, 6, 8) or COLORS.Muted
        pcall(function() button:SetAttribute("AeroIdleColor", button.BackgroundColor3) end)
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
            Size = UDim2.fromOffset(690, 510),
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

    -- Remove only an older copy of this script's own GUI.
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

    Main = create("Frame", {
        Name = "Main",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(690, 510),
        BackgroundColor3 = COLORS.Background,
        BackgroundTransparency = CONFIG.WindowTransparency,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, GUI)
    corner(Main, 15)
    local outerStroke = stroke(Main, Color3.fromRGB(185, 188, 196), 0.16)
    if outerStroke then
        create("UIGradient", {
            Rotation = 0,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(70, 72, 80)),
                ColorSequenceKeypoint.new(0.48, Color3.fromRGB(245, 246, 250)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(76, 78, 86)),
            }),
        }, outerStroke)
    end

    Header = create("Frame", {
        Name = "Header",
        BackgroundColor3 = Color3.fromRGB(9, 10, 12),
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 58),
    }, Main)
    corner(Header, 12)

    local title = makeLabel(Header, "A E R O   /   REVENGERS X", 15, COLORS.Text, Enum.Font.GothamBold)
    title.Position = UDim2.new(0, 20, 0, 4)
    title.Size = UDim2.new(0, 300, 0, 28)
    UIRefs.Title = title
    local subtitle = makeLabel(Header, "DEFENSE INTERFACE     /     CLIENT BUILD", 9, COLORS.Muted)
    subtitle.Position = UDim2.new(0, 21, 0, 31)
    subtitle.Size = UDim2.new(0, 330, 0, 15)

    local shimmer = create("Frame", {
        Name = "WhiteShimmer",
        BackgroundColor3 = COLORS.White,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -2),
        Size = UDim2.new(1, 0, 0, 2),
    }, Header)
    local shimmerGradient = create("UIGradient", {
        Rotation = 0,
        Offset = Vector2.new(-1, 0),
        Color = ColorSequence.new(Color3.fromRGB(40, 42, 48), Color3.fromRGB(255, 255, 255)),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.42, 1),
            NumberSequenceKeypoint.new(0.50, 0.05),
            NumberSequenceKeypoint.new(0.58, 1),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }, shimmer)
    UIRefs.Shimmer = shimmerGradient

    local gradient = create("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(118, 121, 130)),
            ColorSequenceKeypoint.new(0.48, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(145, 149, 158)),
        }),
        Rotation = 0,
        Offset = Vector2.new(-0.5, 0),
        Enabled = CONFIG.AnimateHeader,
    }, title)
    UIRefs.Gradient = gradient

    local statusPill = create("Frame", {
        Name = "StatusPill",
        BackgroundColor3 = Color3.fromRGB(18, 19, 23),
        BorderSizePixel = 0,
        Position = UDim2.new(1, -238, 0, 15),
        Size = UDim2.fromOffset(132, 27),
    }, Header)
    corner(statusPill, 14)
    stroke(statusPill, Color3.fromRGB(76, 79, 88), 0.48)
    local statusDot = create("Frame", {
        BackgroundColor3 = Color3.fromRGB(235, 238, 244),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 10, 0.5, -3),
        Size = UDim2.fromOffset(6, 6),
    }, statusPill)
    corner(statusDot, 5)
    local statusText = makeLabel(statusPill, "DEFENSE READY", 9, COLORS.Text, Enum.Font.GothamBold)
    statusText.Position = UDim2.new(0, 23, 0, 0)
    statusText.Size = UDim2.new(1, -28, 1, 0)

    local close = makeButton(Header, "—", function() setMenuVisible(false) end, 32)
    close.Position = UDim2.new(1, -48, 0, 14)
    close.Size = UDim2.fromOffset(28, 28)
    local unload = makeButton(Header, "×", function()
        if type(_G.AERO_REVENGERS_UNLOAD) == "function" then _G.AERO_REVENGERS_UNLOAD() end
    end, 32)
    unload.Position = UDim2.new(1, -84, 0, 14)
    unload.Size = UDim2.fromOffset(28, 28)
    unload.TextColor3 = COLORS.Danger

    local nav = create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 18, 0, 70),
        Size = UDim2.new(1, -36, 0, 38),
    }, Main)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, nav)

    for _, tabName in ipairs({ "Combat", "Settings", "Theme" }) do
        local button = makeButton(nav, string.upper(tabName), function() setTab(tabName) end, 112)
        button.Size = UDim2.new(0, 126, 1, 0)
        TabButtons[tabName] = button
    end

    Content = create("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 18, 0, 122),
        Size = UDim2.new(1, -36, 1, -138),
    }, Main)

    ToastHolder = create("Frame", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 18),
        Size = UDim2.new(0, 230, 0, 120),
    }, GUI)
    create("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Top,
    }, ToastHolder)

    local combat = createPage("Combat")
    local settings = createPage("Settings")
    local theme = createPage("Theme")

    -- Combat tab
    pageSection(combat, "Defense")
    addToggle(combat, "Auto Block", "AutoBlock")
    addBind(combat, "Block key", "BlockKey")
    addToggle(combat, "Auto Parry / Dodge", "AutoDodge")
    addBind(combat, "Dodge key", "DodgeKey")
    addToggle(combat, "Facing check", "FacingCheck")
    addToggle(combat, "Ping compensation", "PingCompensation")
    addToggle(combat, "Post-hit recovery", "RecoveryEnabled")
    pageSection(combat, "Timing / target filter")
    addSlider(combat, "Max distance", "MaxDistance", 5, 40, 0)
    addSlider(combat, "Block lead (sec)", "BlockLead", 0.05, 0.60, 2)
    addSlider(combat, "Dodge lead (sec)", "DodgeLead", 0.03, 0.40, 2)
    addSlider(combat, "Facing threshold", "FacingDot", -0.1, 0.9, 2)
    addSlider(combat, "Estimated impact ratio", "ImpactRatio", 0.35, 0.95, 2)
    addSlider(combat, "Learn range", "LearnDistance", 5, 35, 0)
    addToggle(combat, "Immediate fallback while Length loads", "ZeroLengthFallback")
    addToggle(combat, "Use named hit keyframes when present", "UseKeyframeMarkers")
    addToggle(combat, "Early guard on Action animations", "EarlyActionGuard")
    addToggle(combat, "Action-priority filter", "PriorityFilter")
    addCycle(combat, "Animation filter", "FilterMode", { "NonLooped", "Whitelist" })
    local whitelistRow = pageRow(combat, 42)
    local whitelistBox = create("TextBox", {
        BackgroundColor3 = COLORS.Panel2,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        PlaceholderText = "Animation IDs, comma-separated",
        Text = table.concat(CONFIG.AttackWhitelist, ","),
        TextColor3 = COLORS.Text,
        PlaceholderColor3 = COLORS.Muted,
        TextSize = 10,
        Font = Enum.Font.Gotham,
        Position = UDim2.new(0, 8, 0, 6),
        Size = UDim2.new(1, -102, 0, 30),
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
    end, 78)
    applyWhitelist.Position = UDim2.new(1, -88, 0.5, -15)
    pageSection(combat, "Tools")
    addToggle(combat, "Learn mode (heuristic logging)", "LearnMode")
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

    -- Settings tab
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
            Version = CONFIG.Version,
            MenuKey = CONFIG.MenuKey, BlockKey = CONFIG.BlockKey, DodgeKey = CONFIG.DodgeKey,
            AutoBlock = CONFIG.AutoBlock, AutoDodge = CONFIG.AutoDodge,
            FacingCheck = CONFIG.FacingCheck, FacingDot = CONFIG.FacingDot,
            MaxDistance = CONFIG.MaxDistance, PingCompensation = CONFIG.PingCompensation,
            ManualPingMs = CONFIG.ManualPingMs, BlockLead = CONFIG.BlockLead,
            DodgeLead = CONFIG.DodgeLead, DodgeCooldown = CONFIG.DodgeCooldown,
            DodgeTapDuration = CONFIG.DodgeTapDuration, BlockHoldAfterImpact = CONFIG.BlockHoldAfterImpact,
            ComboGap = CONFIG.ComboGap, LateWindow = CONFIG.LateWindow,
            MaxBlockCommit = CONFIG.MaxBlockCommit, UseKeyframeMarkers = CONFIG.UseKeyframeMarkers,
            EarlyActionGuard = CONFIG.EarlyActionGuard,
            FilterMode = CONFIG.FilterMode, ImpactRatio = CONFIG.ImpactRatio,
            InputMode = CONFIG.InputMode, InputMethod = CONFIG.InputMethod,
            WindowTransparency = CONFIG.WindowTransparency, Accent = CONFIG.Accent,
            AnimateHeader = CONFIG.AnimateHeader, LearnedTimings = CONFIG.LearnedTimings,
            AttackWhitelist = CONFIG.AttackWhitelist,
            LearnDistance = CONFIG.LearnDistance, ZeroLengthFallback = CONFIG.ZeroLengthFallback,
            ZeroLengthHold = CONFIG.ZeroLengthHold, MaxTrackAge = CONFIG.MaxTrackAge,
            PriorityFilter = CONFIG.PriorityFilter,
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
            "MenuKey", "BlockKey", "DodgeKey", "AutoBlock", "AutoDodge", "FacingCheck", "FacingDot",
            "MaxDistance", "PingCompensation", "ManualPingMs", "BlockLead", "DodgeLead", "DodgeCooldown",
            "DodgeTapDuration", "BlockHoldAfterImpact", "ComboGap", "LateWindow", "FilterMode", "ImpactRatio",
            "MaxBlockCommit", "UseKeyframeMarkers", "EarlyActionGuard",
            "InputMode", "InputMethod", "WindowTransparency", "Accent", "AnimateHeader", "LearnedTimings", "AttackWhitelist",
            "LearnDistance", "ZeroLengthFallback", "ZeroLengthHold", "MaxTrackAge", "PriorityFilter",
        }
        for _, key in ipairs(allowed) do
            local value = data[key]
            if value ~= nil and type(value) == type(DEFAULTS[key]) then
                CONFIG[key] = value
            end
        end
        if type(CONFIG.Accent) ~= "table" or #CONFIG.Accent < 3 then CONFIG.Accent = { 242, 244, 248 } end
        if CONFIG.FilterMode ~= "NonLooped" and CONFIG.FilterMode ~= "Whitelist" then CONFIG.FilterMode = "NonLooped" end
        if CONFIG.InputMode ~= "Auto" and CONFIG.InputMode ~= "Key" and CONFIG.InputMode ~= "Remote" then CONFIG.InputMode = "Auto" end
        if CONFIG.InputMethod ~= "VIM" and CONFIG.InputMethod ~= "keypress" and CONFIG.InputMethod ~= "both" then CONFIG.InputMethod = "VIM" end
        if not getKeyCode(CONFIG.MenuKey) then CONFIG.MenuKey = DEFAULTS.MenuKey end
        if not getKeyCode(CONFIG.BlockKey) then CONFIG.BlockKey = DEFAULTS.BlockKey end
        if not getKeyCode(CONFIG.DodgeKey) then CONFIG.DodgeKey = DEFAULTS.DodgeKey end
        CONFIG.MaxDistance = clamp(tonumber(CONFIG.MaxDistance) or 18, 5, 100)
        CONFIG.FacingDot = clamp(tonumber(CONFIG.FacingDot) or 0.25, -1, 1)
        CONFIG.BlockLead = clamp(tonumber(CONFIG.BlockLead) or 0.22, 0.01, 1)
        CONFIG.DodgeLead = clamp(tonumber(CONFIG.DodgeLead) or 0.12, 0.01, 1)
        CONFIG.DodgeCooldown = clamp(tonumber(CONFIG.DodgeCooldown) or 1.1, 0.1, 10)
        CONFIG.DodgeTapDuration = clamp(tonumber(CONFIG.DodgeTapDuration) or 0.12, 0.03, 1)
        CONFIG.ComboGap = clamp(tonumber(CONFIG.ComboGap) or 0.42, 0, 2)
        CONFIG.MaxBlockCommit = clamp(tonumber(CONFIG.MaxBlockCommit) or 1.35, 0.1, 5)
        CONFIG.ImpactRatio = clamp(tonumber(CONFIG.ImpactRatio) or 0.72, 0.05, 1)
        CONFIG.LearnDistance = clamp(tonumber(CONFIG.LearnDistance) or 22, 5, 100)
        CONFIG.ZeroLengthHold = clamp(tonumber(CONFIG.ZeroLengthHold) or 0.24, 0.05, 1)
        CONFIG.MaxTrackAge = clamp(tonumber(CONFIG.MaxTrackAge) or 2.25, 0.1, 10)
        CONFIG.WindowTransparency = clamp(tonumber(CONFIG.WindowTransparency) or 0.08, 0, 0.8)
        for _, refresh in pairs(UIRefs.Refreshers or {}) do
            pcall(refresh)
        end
        if UIRefs.BindButtons then
            for key, button in pairs(UIRefs.BindButtons) do
                pcall(function() button.Text = CONFIG[key] end)
            end
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
        { "Polar", { 248, 249, 252 } },
        { "Silver", { 185, 191, 202 } },
        { "Ice", { 210, 226, 238 } },
        { "Smoke", { 112, 117, 127 } },
    }
    local presetLayout = create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 6),
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        VerticalAlignment = Enum.VerticalAlignment.Center,
    }, presetRow)
    for _, preset in ipairs(presets) do
        local button = makeButton(presetRow, preset[1], function()
            CONFIG.Accent = { preset[2][1], preset[2][2], preset[2][3] }
            applyTheme()
            toast("Accent: " .. preset[1])
        end, 92)
        button.Size = UDim2.new(0, 92, 0, 29)
    end

    pageSection(theme, "Custom color / window")
    local hexRow = pageRow(theme, 42)
    local hexLabel = makeLabel(hexRow, "HEX", 11, COLORS.Muted, Enum.Font.GothamBold)
    hexLabel.Position = UDim2.new(0, 12, 0, 0)
    hexLabel.Size = UDim2.new(0, 40, 1, 0)
    local hexBox = create("TextBox", {
        BackgroundColor3 = COLORS.Panel2,
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        PlaceholderText = "#735CFF",
        Text = "",
        TextColor3 = COLORS.Text,
        PlaceholderColor3 = COLORS.Muted,
        TextSize = 12,
        Font = Enum.Font.Gotham,
        Position = UDim2.new(0, 58, 0, 6),
        Size = UDim2.new(1, -70, 0, 30),
    }, hexRow)
    corner(hexBox, 6)
    connect(hexBox.FocusLost, function(enterPressed)
        if not enterPressed then return end
        local hex = string.gsub(hexBox.Text, "#", "")
        if #hex == 6 and string.match(hex, "^%x%x%x%x%x%x$") then
            local r = tonumber(string.sub(hex, 1, 2), 16)
            local g = tonumber(string.sub(hex, 3, 4), 16)
            local b = tonumber(string.sub(hex, 5, 6), 16)
            CONFIG.Accent = { r, g, b }
            applyTheme()
            toast("Custom accent applied")
        else
            toast("Enter a 6-digit HEX color", "error")
        end
    end)
    addToggle(theme, "Animated title gradient", "AnimateHeader")
    addSlider(theme, "Window transparency", "WindowTransparency", 0, 0.35, 2, function() applyTheme() end)

    setTab("Combat")
    applyTheme()

    -- Header drag: movement is handled by the shared InputChanged connection below.
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
-- Lifecycle / config callbacks / input events
--==============================================================

local function unload()
    if State.Unloaded then return end
    State.Unloaded = true

    releaseAllInputs()
    State.ActiveTracks = {}

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
    for i = #State.ActiveTracks, 1, -1 do
        if State.ActiveTracks[i].Player == player then table.remove(State.ActiveTracks, i) end
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

makeUI()

-- Animated monochrome sheen. This is intentionally subtle and fully stopped by Unload.
if UIRefs.Gradient or UIRefs.Shimmer then
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
                task.wait(2.05)
            else
                task.wait(0.25)
            end
        end
    end)
    addThread(thread)
end

print("[Aero] Revengers X toolkit initialized. RightShift toggles the menu; unload with the UI button or _G.AERO_REVENGERS_UNLOAD().")
