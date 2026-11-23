--[[
    Revengers X | Combat Suite  (client executor, Luau)
    ---------------------------------------------------------------------------
    Sections:
      0. Boot            - services, executor capabilities (all pcall-safe), single-instance guard
      1. Config / State  - defaults, runtime state, JSON config I/O
      2. Utils           - Maid, math/colour helpers, tween helper
      3. Input           - key / remote output, anti-stuck, release-all
      4. Combat Core     - threat tracking, Auto Block, Recovery, Dodge, Learn mode
      5. UI Library      - window, tabs, components, toasts
      6. Tabs            - Combat / Settings / Theme
      7. Lifecycle       - event wiring, main loops, Unload

    Hotkeys:  RightShift = menu (changeable)  |  H = Auto Block toggle  |  J = Auto Dodge toggle
    Notes:    Remote names and stun names of the game are unknown -> Remote mode and
              stun detection are best-effort heuristics (see STUN_PATTERNS / REMOTE_PATTERNS).
]]

--==============================================================================
-- 0. BOOT
--==============================================================================
if not game:IsLoaded() then game.Loaded:Wait() end

local function getService(name)
    local ok, svc = pcall(game.GetService, game, name)
    if not ok or not svc then return nil end
    if typeof(cloneref) == "function" then
        local ok2, clone = pcall(cloneref, svc)
        if ok2 and clone then return clone end
    end
    return svc
end

local Players          = getService("Players")
local RunService       = getService("RunService")
local UserInputService = getService("UserInputService")
local TweenService     = getService("TweenService")
local HttpService      = getService("HttpService")
local Stats            = getService("Stats")
local CoreGui          = getService("CoreGui")
local VIM              = getService("VirtualInputManager")

assert(Players and RunService and UserInputService and TweenService and HttpService, "[RevengersX] core services missing")
local LP = Players.LocalPlayer

-- Executor capability table: every entry is either a function or nil
local function fn(f) return typeof(f) == "function" and f or nil end
local function safeGet(getter)
    local ok, v = pcall(getter)
    return ok and v or nil
end

local Exec = {
    getgenv   = fn(getgenv),
    gethui    = fn(gethui),
    writefile = fn(writefile),
    readfile  = fn(readfile),
    isfile    = fn(isfile),
    isfolder  = fn(isfolder),
    makefolder= fn(makefolder),
    keypress  = fn(keypress),
    keyrelease= fn(keyrelease),
    protect   = fn(safeGet(function() return syn.protect_gui end))
             or fn(safeGet(function() return protectgui end))
             or fn(safeGet(function() return protect_gui end)),
}

-- Global environment + single instance guard (re-execute = clean reload)
local env = (Exec.getgenv and safeGet(Exec.getgenv)) or _G
if type(env) ~= "table" then env = _G end
if env.RevengersX and type(env.RevengersX.Unload) == "function" then
    pcall(env.RevengersX.Unload)
    task.wait(0.15)
end

--==============================================================================
-- 1. CONFIG / STATE
--==============================================================================
local Defaults = {
    Block = {
        Enabled = false, Bind = "H",
        Lead = 0.10,            -- extra safety margin before the hit (s)
        Hold = 0.35,            -- how long to keep block after the hit lands (s)
        ComboBridge = 0.35,     -- extra hold bridging the gap to the next hit of a combo (s)
        ComboGap = 0.90,        -- max time between attack starts to count as one combo (s)
        ComboMax = 5,           -- hits in a full string
        Recovery = true,        -- post-hit / hitstun recovery mode
        RecoveryWindow = 0.70,  -- how long after being hit we try to re-block (s)
    },
    Dodge = {
        Enabled = false, Bind = "J",
        Lead = 0.06, Cooldown = 1.20, Tap = 0.08,
        Fallback = true,        -- fall back to Auto Block if dodge is on cooldown / unavailable
    },
    Detect = {
        MaxDistance = 20,
        FacingCheck = true, FacingThreshold = 0.30,
        PingComp = true, PingScale = 1.0,
        Filter = "All",         -- "All" (every non-looped combat anim) | "Learned" (only learned attacks)
        HitFraction = 0.35,     -- default hit moment as fraction of animation length
        IgnoreTeam = true, IgnoreFriends = true,
    },
    Input = {
        Mode = "Auto",          -- Auto | Key | Remote
        Method = "VIM",         -- VIM | keypress | Both
        BlockKey = "F", DodgeKey = "Q", MenuKey = "RightShift",
        MaxHold = 5.0,          -- anti-stuck watchdog (s)
    },
    Theme = { Accent = "E5334F", AnimateTitle = true, Transparency = 0.04 },
    Learned = {},               -- [animId] = { hit = animTimePosition, n = samples }
}

local function deepCopy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = type(v) == "table" and deepCopy(v) or v end
    return c
end

local Cfg = deepCopy(Defaults)

local State = {
    Unloaded = false, Learn = false, MenuOpen = false,
    Stunned = false, PrevStunned = false, Ping = 0.05,
}

-- Merge decoded JSON into Cfg *in place* (UI components keep their table references)
local function deepMerge(dst, src)
    for k, v in pairs(src) do
        local d = dst[k]
        if k == "Learned" and type(v) == "table" then
            local clean = {}
            for id, e in pairs(v) do
                if type(e) == "table" and type(e.hit) == "number" then
                    clean[tostring(id)] = { hit = e.hit, n = tonumber(e.n) or 1 }
                end
            end
            dst[k] = clean
        elseif type(d) == "table" and type(v) == "table" then
            deepMerge(d, v)
        elseif d ~= nil and type(d) == type(v) then
            dst[k] = v
        end
    end
end

local UI = { Elements = {}, AccentHooks = {}, Gradients = {}, Accent = Color3.fromRGB(229, 51, 79) }
local Combat, Block -- forward declarations

local function log(fmt, ...)
    local ok, msg = pcall(string.format, "[RevengersX] " .. fmt, ...)
    print(ok and msg or fmt)
end

--==============================================================================
-- 2. UTILS
--==============================================================================
local Maid = {}
Maid.__index = Maid
function Maid.new() return setmetatable({ _items = {}, _dead = false }, Maid) end

local function disposeItem(x)
    pcall(function()
        local ty = typeof(x)
        if ty == "RBXScriptConnection" then x:Disconnect()
        elseif ty == "Instance" then x:Destroy()
        elseif ty == "function" then x()
        elseif ty == "thread" then task.cancel(x)
        elseif type(x) == "table" and type(x.Destroy) == "function" then x:Destroy() end
    end)
end
function Maid:Add(x)
    if self._dead then disposeItem(x) else table.insert(self._items, x) end
    return x
end
function Maid:Clean()
    local items = self._items
    self._items = {}
    for i = #items, 1, -1 do disposeItem(items[i]) end
end
function Maid:Destroy() self._dead = true; self:Clean() end

local MainMaid = Maid.new()

local function toHex(c)
    return string.format("%02X%02X%02X", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end
local function fromHex(s)
    s = (tostring(s or ""):gsub("[#%s]", ""))
    if #s == 3 then s = s:gsub(".", "%0%0") end
    if not s:match("^%x%x%x%x%x%x$") then return nil end
    return Color3.fromRGB(tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16))
end
local function keyCode(name)
    if not name or name == "None" then return nil end
    local ok, kc = pcall(function() return Enum.KeyCode[name] end)
    return ok and kc or nil
end
local function tween(inst, info, props)
    local ok, tw = pcall(TweenService.Create, TweenService, inst, info, props)
    if ok and tw then tw:Play() return tw end
end

--==============================================================================
-- 3. INPUT  (key emulation / remote, anti-stuck)
--==============================================================================
local Input = { held = {} }

local VK_SPECIAL = {
    LeftShift = 0xA0, RightShift = 0xA1, LeftControl = 0xA2, RightControl = 0xA3,
    LeftAlt = 0xA4, RightAlt = 0xA5, CapsLock = 0x14, Left = 0x25, Up = 0x26, Right = 0x27, Down = 0x28,
}
-- Roblox KeyCode -> Windows virtual-key code (for keypress/keyrelease)
local function toVK(kc)
    if VK_SPECIAL[kc.Name] then return VK_SPECIAL[kc.Name] end
    local v = kc.Value
    if v >= 97 and v <= 122 then return v - 32 end      -- a-z -> A-Z
    if v >= 282 and v <= 293 then return 0x70 + (v - 282) end -- F1..F12
    if v < 97 then return v end                         -- digits, space, tab, return, esc...
    return nil
end

local REMOTE_PATTERNS = {
    Block = { "block", "guard" },
    Dodge = { "dodge", "dash", "roll", "evade" },
}
local remoteCache = {}
local function findRemote(action)
    local c = remoteCache[action]
    if c and c.inst and c.inst.Parent then return c.inst end
    if c and os.clock() - c.t < 5 then return nil end
    local found
    pcall(function()
        local rs = getService("ReplicatedStorage")
        for _, d in ipairs(rs:GetDescendants()) do
            if d:IsA("RemoteEvent") then
                local n = d.Name:lower()
                for _, p in ipairs(REMOTE_PATTERNS[action]) do
                    if n:find(p, 1, true) then found = d break end
                end
            end
            if found then break end
        end
    end)
    remoteCache[action] = { inst = found, t = os.clock() }
    return found
end

function Input.methods()
    local list = {}
    if VIM then table.insert(list, "VIM") end
    if Exec.keypress and Exec.keyrelease then table.insert(list, "keypress") end
    if #list == 2 then table.insert(list, "Both") end
    if #list == 0 then list = { "None" } end
    return list
end
function Input.normalize()
    local list = Input.methods()
    if not table.find(list, Cfg.Input.Method) then Cfg.Input.Method = list[1] end
end
function Input.keyAvailable() return Input.methods()[1] ~= "None" end
function Input.resolveMode()
    local m = Cfg.Input.Mode
    if m == "Auto" then return Input.keyAvailable() and "Key" or "Remote" end
    return m
end

local function keySend(kc, down)
    local m, ok = Cfg.Input.Method, false
    if (m == "VIM" or m == "Both") and VIM then
        ok = pcall(function() VIM:SendKeyEvent(down, kc, false, game) end) or ok
    end
    if (m == "keypress" or m == "Both") and Exec.keypress and Exec.keyrelease then
        local vk = toVK(kc)
        if vk then ok = pcall(down and Exec.keypress or Exec.keyrelease, vk) or ok end
    end
    if not ok then -- chosen backend unavailable/failed -> try any other
        if VIM then ok = pcall(function() VIM:SendKeyEvent(down, kc, false, game) end) end
        if not ok and Exec.keypress and Exec.keyrelease then
            local vk = toVK(kc)
            if vk then ok = pcall(down and Exec.keypress or Exec.keyrelease, vk) end
        end
    end
    return ok
end

local function dispatch(action, keyName, mode, down)
    local ok = false
    if mode == "Key" then
        local kc = keyCode(keyName)
        if kc then ok = keySend(kc, down) end
    end
    if not ok and (mode == "Remote" or Cfg.Input.Mode == "Auto") then
        local r = findRemote(action)
        if r then ok = pcall(function() r:FireServer(down) end) end
    end
    return ok
end

function Input.press(action)
    if State.Unloaded or Input.held[action] then return end
    if UserInputService:GetFocusedTextBox() then return end -- never type into chat
    local keyName = action == "Block" and Cfg.Input.BlockKey or Cfg.Input.DodgeKey
    local mode = Input.resolveMode()
    if dispatch(action, keyName, mode, true) then
        Input.held[action] = { key = keyName, mode = mode, t = os.clock() }
    end
end
function Input.release(action)
    local h = Input.held[action]
    if not h then return end
    Input.held[action] = nil
    dispatch(action, h.key, h.mode, false)
end
function Input.releaseAll()
    local actions = {}
    for a in pairs(Input.held) do table.insert(actions, a) end
    for _, a in ipairs(actions) do Input.release(a) end
end
function Input.tap(action, dur)
    Input.press(action)
    if not Input.held[action] then return end
    task.delay(math.max(dur, 0.02), function() Input.release(action) end)
end
function Input.watchdog(now) -- anti-stuck: force release after MaxHold
    for a, h in pairs(Input.held) do
        if now - h.t > Cfg.Input.MaxHold then Input.release(a) end
    end
end

--==============================================================================
-- 4. COMBAT CORE
--==============================================================================
Combat = {
    Active = {},        -- [track] = threat
    LearnTracks = {},   -- [track] = info (Learn mode)
    Chains = {},        -- [player] = { count, lastStart }
    Hooks = {},         -- [player] = { persist, char }
    Friends = {},
    dodgeLast = -1e9, recoveryUntil = 0, lastPing = 0, lastStun = 0,
}
Block = { holdUntil = 0 }

local STUN_PATTERNS = { "stun", "ragdoll", "stagger" }
local function matchesStun(name)
    name = name:lower()
    for _, p in ipairs(STUN_PATTERNS) do if name:find(p, 1, true) then return true end end
    return false
end

local function localRefs()
    local char = LP.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if hum and root and hum.Health > 0 then return char, hum, root end
end

local function refreshPing()
    local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000 end)
    if not ok or type(v) ~= "number" then
        ok, v = pcall(function() return LP:GetNetworkPing() * 2 end)
    end
    if ok and type(v) == "number" then State.Ping = v end
end
local function pingComp()
    if not Cfg.Detect.PingComp then return 0 end
    return math.clamp(State.Ping * Cfg.Detect.PingScale, 0, 0.35)
end

-- Hitstun heuristics (cached at 20 Hz)
local function updateStun(now)
    if now - Combat.lastStun < 0.05 then return end
    Combat.lastStun = now
    local char, hum = localRefs()
    if not char then State.Stunned = true return end
    local s = hum.PlatformStand or hum.WalkSpeed <= 0.5
    if not s then
        local st = hum:GetState()
        s = st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown
            or st == Enum.HumanoidStateType.Physics
    end
    if not s then
        for _, c in ipairs(char:GetChildren()) do
            if matchesStun(c.Name) then
                if c:IsA("BoolValue") then s = c.Value
                elseif c:IsA("NumberValue") or c:IsA("IntValue") then s = c.Value > 0
                else s = true end
                if s then break end
            end
        end
    end
    if not s then
        for k, v in pairs(char:GetAttributes()) do
            if matchesStun(k) and (v == true or (type(v) == "number" and v > 0)) then s = true break end
        end
    end
    State.Stunned = s and true or false
end

local function attackerValid(plr, char)
    if plr == LP then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end                  -- dead / inactive
    if char:FindFirstChildOfClass("ForceField") then return false end
    if Cfg.Detect.IgnoreTeam and plr.Team ~= nil and plr.Team == LP.Team then return false end
    if Cfg.Detect.IgnoreFriends and Combat.Friends[plr.UserId] then return false end
    return true
end

-- distance + facing check; returns ok, distance
local function inRange(attRoot, myRoot)
    local off = myRoot.Position - attRoot.Position
    local dist = off.Magnitude
    if dist > Cfg.Detect.MaxDistance then return false, dist end
    if Cfg.Detect.FacingCheck and dist > 4.5 then
        local flat = Vector3.new(off.X, 0, off.Z)
        if flat.Magnitude > 0.01 then
            local look = attRoot.CFrame.LookVector
            look = Vector3.new(look.X, 0, look.Z)
            if look.Magnitude > 0.01 and look.Unit:Dot(flat.Unit) < Cfg.Detect.FacingThreshold then
                return false, dist
            end
        end
    end
    return true, dist
end

---------------------------------------------------------------- Block controller
function Block.isHeld() return Input.held.Block ~= nil end

-- Extend the hold window. chain >= 2 bridges the gap to the next hit of a combo.
function Block.request(now, tth, t)
    local c = Cfg.Block
    local chain = (t and t.chain) or 1
    local untilT = now + math.max(tth, 0) + c.Hold
    if chain >= 2 and chain < c.ComboMax then untilT = untilT + c.ComboBridge end
    if untilT > Block.holdUntil then Block.holdUntil = untilT end
end
function Block.update(now)
    local want = now < Block.holdUntil
    if want and not Input.held.Block then Input.press("Block")
    elseif not want and Input.held.Block then Input.release("Block") end
end

---------------------------------------------------------------- Dodge
function Combat.dodgeReady(now) return now - Combat.dodgeLast >= Cfg.Dodge.Cooldown end
function Combat.doDodge(now)
    Combat.dodgeLast = now
    Input.tap("Dodge", Cfg.Dodge.Tap)
end

---------------------------------------------------------------- Track handling
function Combat.onTrack(plr, char, track)
    if State.Unloaded then return end
    local okA, rawId = pcall(function() return track.Animation.AnimationId end)
    rawId = okA and tostring(rawId) or ""
    local key = rawId:match("%d+") or rawId
    if track.Looped then return end

    local _, _, myRoot = localRefs()
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local dist = (myRoot and hrp) and (myRoot.Position - hrp.Position).Magnitude or math.huge
    local pr = track.Priority
    local idle = pr == Enum.AnimationPriority.Idle or pr == Enum.AnimationPriority.Movement
        or pr == Enum.AnimationPriority.Core

    -- Learn mode: log + remember tracks so that a received hit can be attributed
    if State.Learn and dist <= 60 then
        log("LEARN | %s | id=%s | len=%.2fs | speed=%.2f | prio=%s | dist=%.1f | learned=%s",
            plr.Name, key, track.Length, track.Speed, pr.Name, dist, tostring(Cfg.Learned[key] ~= nil))
        if not idle then
            Combat.LearnTracks[track] = { key = key, plr = plr, char = char, start = os.clock() }
        end
    end

    -- Threat filter
    if Cfg.Detect.Filter == "Learned" then
        if not Cfg.Learned[key] then return end
    elseif idle then return end
    if track.Length < 0.1 or not attackerValid(plr, char) then return end
    if dist > Cfg.Detect.MaxDistance * 2 + 10 then return end

    local now = os.clock()
    local ch = Combat.Chains[plr]
    if ch and now - ch.lastStart <= Cfg.Block.ComboGap then
        ch.count = (ch.count >= Cfg.Block.ComboMax) and 1 or (ch.count + 1)
    else
        ch = { count = 1 }
        Combat.Chains[plr] = ch
    end
    ch.lastStart = now

    local learned = Cfg.Learned[key]
    local hitPos = learned and learned.hit or math.clamp(track.Length * Cfg.Detect.HitFraction, 0.08, 0.55)
    Combat.Active[track] = { plr = plr, char = char, track = track, id = key, hitPos = hitPos, chain = ch.count }
end

-- Attribute a received hit to the most recent nearby attack animation (Learn mode)
function Combat.learnHit(now)
    local _, _, myRoot = localRefs()
    if not myRoot then return end
    local best, bestInfo
    for track, info in pairs(Combat.LearnTracks) do
        local hrp = info.char:FindFirstChild("HumanoidRootPart")
        if track.IsPlaying and hrp and (hrp.Position - myRoot.Position).Magnitude <= 20 and now - info.start < 1.5 then
            if not bestInfo or info.start > bestInfo.start then best, bestInfo = track, info end
        end
    end
    if not best then return end
    local tp = best.TimePosition
    local e = Cfg.Learned[bestInfo.key]
    if e then
        e.hit = (e.hit * e.n + tp) / (e.n + 1)
        e.n = math.min(e.n + 1, 8)
    else
        Cfg.Learned[bestInfo.key] = { hit = tp, n = 1 }
    end
    log("LEARN HIT | %s | id=%s | hit@%.3f (anim time) | real=%.3fs after start | speed=%.2f",
        bestInfo.plr.Name, bestInfo.key, tp, now - bestInfo.start, best.Speed)
    if UI.UpdateLearned then UI.UpdateLearned() end
end

function Combat.onDamaged(now)
    Combat.recoveryUntil = now + Cfg.Block.RecoveryWindow
    if State.Learn then Combat.learnHit(now) end
end

function Combat.clear()
    table.clear(Combat.Active)
    table.clear(Combat.LearnTracks)
    table.clear(Combat.Chains)
end

---------------------------------------------------------------- Main step (Heartbeat)
function Combat.step(now)
    if now - Combat.lastPing > 0.5 then Combat.lastPing = now; refreshPing() end
    Input.watchdog(now)

    local char, _, myRoot = localRefs()
    if not char then
        Combat.clear()
        Block.holdUntil = 0
        Block.update(now)
        return
    end
    updateStun(now)

    local pc = pingComp()
    local bLead, dLead = Cfg.Block.Lead + pc, Cfg.Dodge.Lead + pc
    local blockOn, dodgeOn = Cfg.Block.Enabled, Cfg.Dodge.Enabled
    local closeThreat = nil

    for track, t in pairs(Combat.Active) do
        local hrp = t.char.Parent and t.char:FindFirstChild("HumanoidRootPart")
        if not track.IsPlaying or not hrp or not attackerValid(t.plr, t.char) then
            Combat.Active[track] = nil
        else
            local ok, dist = inRange(hrp, myRoot)
            local speed = math.max(track.Speed, 0.05)            -- animation speed aware
            local tth = (t.hitPos - track.TimePosition) / speed  -- time to hit (s)

            if ok and dist <= math.min(Cfg.Detect.MaxDistance, 12) and (tth > -0.3 or t.chain >= 2) then
                closeThreat = t
            end

            if ok and not t.done and (blockOn or dodgeOn) then
                -- 1) decide plan once the hit is close enough
                if not t.plan then
                    if tth < -0.15 then
                        t.done = true -- we saw this attack too late
                    elseif tth <= math.max(bLead, dLead) then
                        if dodgeOn and Combat.dodgeReady(now) then t.plan = "dodge"
                        elseif blockOn then t.plan = "block"
                        else t.done = true end
                    end
                end
                -- 2) dodge execution (with fallback to block)
                if t.plan == "dodge" and not t.done and tth <= dLead then
                    if not State.Stunned and Combat.dodgeReady(now) then
                        Combat.doDodge(now)
                        t.done = true
                    elseif blockOn and (Cfg.Dodge.Fallback or State.Stunned) then
                        t.plan = "block"
                    else
                        t.done = true
                    end
                end
                -- 3) block execution; hitstun -> defer instead of wasting the reaction
                if t.plan == "block" and not t.done and tth <= bLead then
                    if State.Stunned and Cfg.Block.Recovery then
                        if not t.deferred then t.deferred = true; t.deferAt = now end
                        local chain = Combat.Chains[t.plr]
                        local chaining = chain and chain.count >= 2 and now - chain.lastStart <= Cfg.Block.ComboGap
                        if now - t.deferAt > Cfg.Block.RecoveryWindow and not chaining then t.done = true end
                    else
                        Block.request(now, tth, t) -- if deferred, tth <= 0 -> press immediately
                        t.done = true
                    end
                end
            elseif ok and t.done and t.plan == "block" and Block.isHeld() and t.chain >= 2 then
                -- combo sustain: keep block alive while this attacker keeps swinging
                Block.request(now, 0.12 - Cfg.Block.Hold, t)
            end
        end
    end

    -- Post-hit recovery: just got hit, window opened again, enemy still pressing -> block now
    if blockOn and Cfg.Block.Recovery and now < Combat.recoveryUntil and closeThreat
        and not State.Stunned and not Block.isHeld() and now >= Block.holdUntil then
        Block.request(now, 0, closeThreat)
    end
    -- Stun just ended while we still need block -> re-press (game dropped the old press)
    if Cfg.Block.Recovery and State.PrevStunned and not State.Stunned and Input.held.Block and now < Block.holdUntil then
        Input.release("Block")
    end
    State.PrevStunned = State.Stunned

    Block.update(now)

    for p, c in pairs(Combat.Chains) do
        if now - c.lastStart > 5 then Combat.Chains[p] = nil end
    end
    for track in pairs(Combat.LearnTracks) do
        if not track.IsPlaying then Combat.LearnTracks[track] = nil end
    end
end

---------------------------------------------------------------- Player hooks
function Combat.hookPlayer(plr)
    if plr == LP or Combat.Hooks[plr] then return end
    local h = { persist = Maid.new(), char = nil }
    Combat.Hooks[plr] = h

    task.spawn(function()
        local ok, f = pcall(LP.IsFriendsWith, LP, plr.UserId)
        if ok then Combat.Friends[plr.UserId] = f end
    end)

    local function onChar(char)
        if h.char then h.char:Destroy() end
        local cm = Maid.new()
        h.char = cm
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 8)
            if not hum or State.Unloaded then return end
            local animator = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5)
            if not animator or State.Unloaded then return end
            cm:Add(animator.AnimationPlayed:Connect(function(track)
                local ok, err = pcall(Combat.onTrack, plr, char, track)
                if not ok then log("onTrack error: %s", tostring(err)) end
            end))
        end)
    end
    if plr.Character then onChar(plr.Character) end
    h.persist:Add(plr.CharacterAdded:Connect(onChar))
end
function Combat.unhookPlayer(plr)
    local h = Combat.Hooks[plr]
    if not h then return end
    h.persist:Destroy()
    if h.char then h.char:Destroy() end
    Combat.Hooks[plr] = nil
end

-- Local character: damage detection + death cleanup
local charMaid = Maid.new()
MainMaid:Add(charMaid)
local function hookLocalCharacter(char)
    charMaid:Clean()
    Input.releaseAll()
    Block.holdUntil = 0
    Combat.clear()
    task.spawn(function()
        local hum = char:WaitForChild("Humanoid", 10)
        if not hum or State.Unloaded then return end
        local last = hum.Health
        charMaid:Add(hum.HealthChanged:Connect(function(h)
            if h < last - 0.01 then Combat.onDamaged(os.clock()) end
            last = h
        end))
        charMaid:Add(hum.Died:Connect(function()
            Block.holdUntil = 0
            Input.releaseAll()
            Combat.clear()
        end))
    end)
end

-- Feature toggle side effects (shared by UI click and hotkey)
function Combat.onFeatureToggle(name, v)
    if name == "Auto Block" and not v then
        Block.holdUntil = 0
        Input.release("Block")
    end
    UI.Toast(name .. ": " .. (v and "ON" or "OFF"), v and "on" or "off")
end
function Combat.testBlock()
    Block.holdUntil = os.clock() + 0.8
    UI.Toast("Block test (0.8s)", "info")
end
function Combat.testDodge()
    Combat.doDodge(os.clock())
    UI.Toast("Dodge test", "info")
end

--==============================================================================
-- CONFIG I/O
--==============================================================================
local ConfigIO = { Folder = "RevengersX", File = "Config.json" }
function ConfigIO.available()
    return Exec.writefile ~= nil and Exec.readfile ~= nil and Exec.isfile ~= nil
end
function ConfigIO.path() return ConfigIO.Folder .. "/" .. ConfigIO.File end

function ConfigIO.save()
    if not ConfigIO.available() then UI.Toast("Config: file API unavailable", "err") return end
    local ok, err = pcall(function()
        if Exec.isfolder and Exec.makefolder and not Exec.isfolder(ConfigIO.Folder) then
            Exec.makefolder(ConfigIO.Folder)
        end
        Exec.writefile(ConfigIO.path(), HttpService:JSONEncode(Cfg))
    end)
    UI.Toast(ok and "Config saved" or "Save failed", ok and "on" or "err")
    if not ok then log("save error: %s", tostring(err)) end
end

function ConfigIO.load()
    if not ConfigIO.available() then UI.Toast("Config: file API unavailable", "err") return end
    local ok, err = pcall(function()
        if not Exec.isfile(ConfigIO.path()) then error("no config file yet", 0) end
        local data = HttpService:JSONDecode(Exec.readfile(ConfigIO.path()))
        deepMerge(Cfg, data)
    end)
    if not ok then UI.Toast("Load failed: " .. tostring(err), "err") return end
    Input.normalize()
    UI.ApplyTheme()
    UI.RefreshAll()
    UI.Toast("Config loaded", "on")
end

--==============================================================================
-- 5. UI LIBRARY
--==============================================================================
local P = {
    Panel = Color3.fromRGB(19, 19, 26), Bg = Color3.fromRGB(13, 13, 18),
    Elem = Color3.fromRGB(26, 26, 35), Hover = Color3.fromRGB(34, 34, 46),
    Stroke = Color3.fromRGB(46, 46, 62), Text = Color3.fromRGB(232, 232, 242), Sub = Color3.fromRGB(138, 138, 158),
}

local function new(class, props, kids)
    local o = Instance.new(class)
    local parent
    for k, v in pairs(props or {}) do
        if k == "Parent" then parent = v else o[k] = v end
    end
    for _, kid in ipairs(kids or {}) do kid.Parent = o end
    if parent then o.Parent = parent end
    return o
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function uiStroke(c, t)
    return new("UIStroke", { Color = c, Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function label(props)
    local p = { BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = P.Text,
        TextXAlignment = Enum.TextXAlignment.Left }
    for k, v in pairs(props) do p[k] = v end
    return new("TextLabel", p)
end
local function accentHook(f) table.insert(UI.AccentHooks, f); pcall(f, UI.Accent) end
local function accentSeq(c)
    return ColorSequence.new({
        ColorSequenceKeypoint.new(0, c),
        ColorSequenceKeypoint.new(0.5, c:Lerp(Color3.new(1, 1, 1), 0.6)),
        ColorSequenceKeypoint.new(1, c),
    })
end

function UI.SetAccent(c, skipSync)
    UI.Accent = c
    Cfg.Theme.Accent = toHex(c)
    for _, f in ipairs(UI.AccentHooks) do pcall(f, c) end
    if not skipSync and UI.SyncTheme then pcall(UI.SyncTheme) end
end

local function mountGui(gui)
    if Exec.protect then pcall(Exec.protect, gui) end
    local candidates = {}
    if Exec.gethui then table.insert(candidates, function() return Exec.gethui() end) end
    if CoreGui then table.insert(candidates, function() return CoreGui end) end
    table.insert(candidates, function() return LP:WaitForChild("PlayerGui", 5) end)
    for _, get in ipairs(candidates) do
        local ok, parent = pcall(get)
        if ok and parent then
            local ok2 = pcall(function() gui.Parent = parent end)
            if ok2 and gui.Parent then return true end
        end
    end
    return false
end

local TAB_COUNT = 3
local Tab = {}
Tab.__index = Tab

function UI.Build()
    local guid = safeGet(function() return HttpService:GenerateGUID(false) end) or "RevengersX"
    local gui = new("ScreenGui", { Name = guid, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
    if not mountGui(gui) then error("[RevengersX] could not mount GUI") end
    UI.Gui = gui
    MainMaid:Add(gui)

    -- Window (CanvasGroup allows smooth group fade)
    local main = new("CanvasGroup", { Name = "Main", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(540, 450), BackgroundColor3 = P.Bg, BorderSizePixel = 0, GroupTransparency = 1,
        Visible = false, Parent = gui }, { corner(10), uiStroke(P.Stroke, 1) })
    local scale = new("UIScale", { Scale = 0.92, Parent = main })
    UI.Main, UI.Scale = main, scale

    -- Header (drag handle)
    local header = new("Frame", { Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = P.Panel, BorderSizePixel = 0, Parent = main })
    local title = label({ Text = "REVENGERS X", Font = Enum.Font.GothamBlack, TextSize = 17, TextColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(16, 6), Size = UDim2.fromOffset(200, 20), Parent = header })
    local titleGrad = new("UIGradient", { Parent = title })
    label({ Text = "Combat Suite  •  v1.0", TextSize = 11, TextColor3 = P.Sub, Position = UDim2.fromOffset(16, 25),
        Size = UDim2.fromOffset(200, 14), Parent = header })
    local close = new("TextButton", { Text = "×", Font = Enum.Font.GothamBold, TextSize = 22, TextColor3 = P.Sub,
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(30, 30),
        BackgroundColor3 = P.Elem, AutoButtonColor = false, Parent = header }, { corner(6) })
    close.MouseEnter:Connect(function() tween(close, TweenInfo.new(0.12), { TextColor3 = P.Text, BackgroundColor3 = P.Hover }) end)
    close.MouseLeave:Connect(function() tween(close, TweenInfo.new(0.12), { TextColor3 = P.Sub, BackgroundColor3 = P.Elem }) end)
    close.MouseButton1Click:Connect(function() UI.SetVisible(false) end)

    local line = new("Frame", { Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0, Parent = main })
    local lineGrad = new("UIGradient", { Parent = line })
    table.insert(UI.Gradients, titleGrad)
    table.insert(UI.Gradients, lineGrad)
    accentHook(function(c) titleGrad.Color = accentSeq(c); lineGrad.Color = accentSeq(c) end)

    -- Tab bar
    local bar = new("Frame", { Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = P.Panel,
        BorderSizePixel = 0, Parent = main })
    local indicator = new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1 / TAB_COUNT, 0, 0, 2),
        BorderSizePixel = 0, Parent = bar })
    accentHook(function(c) indicator.BackgroundColor3 = c end)
    UI.TabBar, UI.Indicator, UI.Tabs = bar, indicator, {}
    UI.PageHost = new("Frame", { Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, 0, 1, -82), BackgroundTransparency = 1,
        ClipsDescendants = true, Parent = main })

    -- Dragging
    local dragging, dragStart, startPos
    MainMaid:Add(header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, main.Position
            local c; c = i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false; c:Disconnect() end
            end)
        end
    end))
    MainMaid:Add(UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))

    -- Toast host
    UI.ToastHolder = new("Frame", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16), Size = UDim2.fromOffset(270, 320),
        BackgroundTransparency = 1, Parent = gui }, {
        new("UIListLayout", { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom,
            HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    -- Title/gradient animation
    MainMaid:Add(RunService.Heartbeat:Connect(function()
        local t = os.clock()
        local off = Cfg.Theme.AnimateTitle and Vector2.new(math.sin(t * 1.4) * 0.6, 0) or Vector2.zero
        for _, g in ipairs(UI.Gradients) do g.Offset = off end
    end))
end

local toastOrder = 0
function UI.Toast(msg, kind)
    if State.Unloaded or not UI.ToastHolder then return end
    local col = kind == "on" and Color3.fromRGB(80, 220, 130) or kind == "off" and Color3.fromRGB(235, 85, 85)
        or kind == "err" and Color3.fromRGB(255, 170, 60) or UI.Accent
    toastOrder += 1
    local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, LayoutOrder = toastOrder, Parent = UI.ToastHolder })
    local card = new("CanvasGroup", { Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(60, 0), GroupTransparency = 1,
        BackgroundColor3 = P.Panel, BorderSizePixel = 0, Parent = holder }, { corner(8), uiStroke(P.Stroke, 1) })
    new("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = col, BorderSizePixel = 0, Parent = card })
    label({ Text = tostring(msg), Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -20, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
    tween(card, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { Position = UDim2.fromOffset(0, 0), GroupTransparency = 0 })

    -- keep at most 5 toasts
    local kids = {}
    for _, k in ipairs(UI.ToastHolder:GetChildren()) do if k:IsA("Frame") then table.insert(kids, k) end end
    if #kids > 5 then table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end); kids[1]:Destroy() end

    task.delay(2.4, function()
        if State.Unloaded or not holder.Parent then return end
        tween(card, TweenInfo.new(0.25), { Position = UDim2.fromOffset(60, 0), GroupTransparency = 1 })
        task.delay(0.3, function() if holder.Parent then holder:Destroy() end end)
    end)
end

local visToken = 0
function UI.SetVisible(v)
    if State.Unloaded or not UI.Main then return end
    State.MenuOpen = v
    visToken += 1
    local my = visToken
    if v then
        UI.Main.Visible = true
        tween(UI.Scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
        tween(UI.Main, TweenInfo.new(0.22), { GroupTransparency = Cfg.Theme.Transparency })
    else
        tween(UI.Scale, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { Scale = 0.94 })
        tween(UI.Main, TweenInfo.new(0.2), { GroupTransparency = 1 })
        task.delay(0.22, function()
            if my == visToken and not State.Unloaded and UI.Main then UI.Main.Visible = false end
        end)
    end
end
function UI.ToggleMenu() UI.SetVisible(not State.MenuOpen) end

function UI.ApplyTheme()
    local c = fromHex(Cfg.Theme.Accent) or Color3.fromRGB(229, 51, 79)
    UI.SetAccent(c, false)
    if State.MenuOpen and UI.Main then UI.Main.GroupTransparency = Cfg.Theme.Transparency end
end

function UI.RefreshAll()
    for _, e in pairs(UI.Elements) do
        if type(e) == "table" and e.Refresh then pcall(e.Refresh) end
    end
end

---------------------------------------------------------------- Tabs
function UI.AddTab(name)
    local idx = #UI.Tabs + 1
    local btn = new("TextButton", { Text = name:upper(), Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = P.Sub,
        Position = UDim2.new((idx - 1) / TAB_COUNT, 0, 0, 0), Size = UDim2.new(1 / TAB_COUNT, 0, 1, -2),
        BackgroundTransparency = 1, AutoButtonColor = false, Parent = UI.TabBar })
    local page = new("ScrollingFrame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y, Visible = false, Parent = UI.PageHost }, {
        new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
        new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 14) }),
    })
    accentHook(function(c) page.ScrollBarImageColor3 = c end)

    local tab = setmetatable({ Page = page, HeaderBtn = btn, Order = 0, Index = idx }, Tab)
    UI.Tabs[idx] = tab
    btn.MouseButton1Click:Connect(function() UI.SelectTab(idx) end)
    if idx == 1 then UI.SelectTab(1, true) end
    return tab
end

function UI.SelectTab(idx, instant)
    for i, t in ipairs(UI.Tabs) do
        t.Page.Visible = (i == idx)
        tween(t.HeaderBtn, TweenInfo.new(0.15), { TextColor3 = i == idx and P.Text or P.Sub })
    end
    tween(UI.Indicator, TweenInfo.new(instant and 0 or 0.25, Enum.EasingStyle.Quint), { Position = UDim2.new((idx - 1) / TAB_COUNT, 0, 1, 0) })
end

local function row(tab, h)
    tab.Order += 1
    return new("Frame", { Size = UDim2.new(1, 0, 0, h or 34), BackgroundColor3 = P.Elem, BorderSizePixel = 0,
        LayoutOrder = tab.Order, Parent = tab.Page }, { corner(6) })
end

function Tab:Section(name)
    self.Order += 1
    local l = label({ Text = name:upper(), Font = Enum.Font.GothamBold, TextSize = 11, Size = UDim2.new(1, 0, 0, 22),
        LayoutOrder = self.Order, Parent = self.Page })
    accentHook(function(c) l.TextColor3 = c end)
end

function Tab:Label(text)
    local r = row(self, 28)
    local l = label({ Text = text, TextSize = 12, TextColor3 = P.Sub, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0), Parent = r })
    return { SetText = function(_, s) l.Text = s end }
end

function Tab:Toggle(o)
    local r = row(self, 34)
    label({ Text = o.Name, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -70, 1, 0), Parent = r })
    local pill = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(38, 20),
        BackgroundColor3 = P.Stroke, BorderSizePixel = 0, Parent = r }, { corner(10) })
    local knob = new("Frame", { Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0, Parent = pill }, { corner(7) })
    local btn = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = r })
    local obj = {}
    local function paint(animate)
        local on = o.Table[o.Key]
        local ti = TweenInfo.new(animate and 0.16 or 0)
        tween(pill, ti, { BackgroundColor3 = on and UI.Accent or P.Stroke })
        tween(knob, ti, { Position = on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3) })
    end
    function obj.Get() return o.Table[o.Key] end
    function obj.Set(_, v, silent)
        o.Table[o.Key] = v and true or false
        paint(true)
        if o.Callback and not silent then pcall(o.Callback, o.Table[o.Key]) end
    end
    function obj.Refresh() paint(false) end
    btn.MouseButton1Click:Connect(function() obj:Set(not o.Table[o.Key]) end)
    accentHook(function() paint(false) end)
    return obj
end

function Tab:Slider(o)
    local r = row(self, 46)
    label({ Text = o.Name, Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -90, 0, 16), Parent = r })
    local val = label({ TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.Sub, AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 6), Size = UDim2.fromOffset(80, 16), Parent = r })
    local track = new("Frame", { Position = UDim2.new(0, 12, 1, -14), Size = UDim2.new(1, -24, 0, 4), BackgroundColor3 = P.Stroke,
        BorderSizePixel = 0, Parent = r }, { corner(2) })
    local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0, Parent = track }, { corner(2) })
    local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(12, 12),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = track }, { corner(6) })
    local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = r })
    local dec = o.Step >= 1 and 0 or o.Step >= 0.1 and 1 or o.Step >= 0.01 and 2 or 3
    local obj = {}
    local function paint()
        local v = o.Table[o.Key]
        local a = math.clamp((v - o.Min) / (o.Max - o.Min), 0, 1)
        fill.Size = UDim2.fromScale(a, 1)
        knob.Position = UDim2.fromScale(a, 0.5)
        val.Text = string.format("%." .. dec .. "f", v) .. (o.Suffix or "")
    end
    local function setFrom(x)
        local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local v = o.Min + a * (o.Max - o.Min)
        v = math.floor(v / o.Step + 0.5) * o.Step
        v = tonumber(string.format("%.4f", math.clamp(v, o.Min, o.Max)))
        o.Table[o.Key] = v
        paint()
        if o.Callback then pcall(o.Callback, v) end
    end
    local dragging = false
    hit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFrom(i.Position.X)
        end
    end)
    MainMaid:Add(UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            setFrom(i.Position.X)
        end
    end))
    MainMaid:Add(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
    function obj.Refresh() paint() end
    accentHook(function(c) fill.BackgroundColor3 = c end)
    paint()
    return obj
end

function Tab:Keybind(o)
    local r = row(self, 34)
    label({ Text = o.Name, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -110, 1, 0), Parent = r })
    local btn = new("TextButton", { Text = "", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = P.Text, AutoButtonColor = false,
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(92, 24),
        BackgroundColor3 = P.Bg, Parent = r }, { corner(5), uiStroke(P.Stroke, 1) })
    local obj = {}
    local function paint() btn.Text = tostring(o.Table[o.Key]) end
    function obj.Refresh() paint() end
    btn.MouseButton1Click:Connect(function()
        if UI.CaptureFn then return end
        btn.Text = "press key..."
        UI.CaptureFn = function(kc)
            if kc == Enum.KeyCode.Escape then paint() return end
            if kc == Enum.KeyCode.Backspace and o.AllowNone then o.Table[o.Key] = "None"
            else o.Table[o.Key] = kc.Name end
            paint()
            UI.Toast(o.Name .. " -> " .. o.Table[o.Key], "info")
            if o.Callback then pcall(o.Callback, o.Table[o.Key]) end
        end
    end)
    paint()
    return obj
end

function Tab:Dropdown(o) -- click cycles through the options
    local r = row(self, 34)
    label({ Text = o.Name, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -130, 1, 0), Parent = r })
    local btn = new("TextButton", { Text = "", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = P.Text, AutoButtonColor = false,
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(112, 24),
        BackgroundColor3 = P.Bg, Parent = r }, { corner(5), uiStroke(P.Stroke, 1) })
    local obj = {}
    local function options() return type(o.Options) == "function" and o.Options() or o.Options end
    local function paint() btn.Text = tostring(o.Table[o.Key]) .. "  ›" end
    function obj.Refresh() paint() end
    btn.MouseButton1Click:Connect(function()
        local list = options()
        local i = table.find(list, o.Table[o.Key]) or 0
        o.Table[o.Key] = list[(i % #list) + 1]
        paint()
        if o.Callback then pcall(o.Callback, o.Table[o.Key]) end
    end)
    paint()
    return obj
end

function Tab:Button(o)
    local r = row(self, 34)
    r.BackgroundTransparency = 1
    local btn = new("TextButton", { Text = o.Name, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = P.Text, AutoButtonColor = false,
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.Elem, Parent = r }, { corner(6), uiStroke(o.Danger and Color3.fromRGB(150, 50, 60) or P.Stroke, 1) })
    btn.MouseEnter:Connect(function() tween(btn, TweenInfo.new(0.12), { BackgroundColor3 = P.Hover }) end)
    btn.MouseLeave:Connect(function() tween(btn, TweenInfo.new(0.12), { BackgroundColor3 = P.Elem }) end)
    btn.MouseButton1Click:Connect(function() if o.Callback then pcall(o.Callback) end end)
    if o.Danger then btn.TextColor3 = Color3.fromRGB(255, 120, 130) end
    return btn
end

function Tab:TextBox(o)
    local r = row(self, 34)
    label({ Text = o.Name, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -120, 1, 0), Parent = r })
    local box = new("TextBox", { Text = o.Default or "", PlaceholderText = o.Placeholder or "", Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = P.Text, PlaceholderColor3 = P.Sub, ClearTextOnFocus = false, AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(100, 24), BackgroundColor3 = P.Bg, Parent = r }, { corner(5), uiStroke(P.Stroke, 1) })
    box.FocusLost:Connect(function() if o.Callback then pcall(o.Callback, box.Text, box) end end)
    return { Box = box, SetText = function(_, s) box.Text = s end }
end

--==============================================================================
-- 6. TABS
--==============================================================================
local function buildTabs()
    ---------------------------------------------------------------- COMBAT
    local T = UI.AddTab("Combat")

    T:Section("Auto Block")
    UI.Elements.AutoBlock = T:Toggle({ Name = "Auto Block", Table = Cfg.Block, Key = "Enabled",
        Callback = function(v) Combat.onFeatureToggle("Auto Block", v) end })
    UI.Elements.BlockBind = T:Keybind({ Name = "Toggle Bind", Table = Cfg.Block, Key = "Bind", AllowNone = true })
    UI.Elements.BlockLead = T:Slider({ Name = "Lead Time", Table = Cfg.Block, Key = "Lead", Min = 0, Max = 0.4, Step = 0.01, Suffix = " s" })
    UI.Elements.BlockHold = T:Slider({ Name = "Hold After Hit", Table = Cfg.Block, Key = "Hold", Min = 0.1, Max = 1.0, Step = 0.05, Suffix = " s" })
    UI.Elements.BlockBridge = T:Slider({ Name = "Combo Bridge (hold between hits)", Table = Cfg.Block, Key = "ComboBridge", Min = 0, Max = 0.8, Step = 0.05, Suffix = " s" })
    UI.Elements.Recovery = T:Toggle({ Name = "Post-Hit Recovery Mode", Table = Cfg.Block, Key = "Recovery",
        Callback = function(v) UI.Toast("Recovery: " .. (v and "ON" or "OFF"), v and "on" or "off") end })
    UI.Elements.RecWin = T:Slider({ Name = "Recovery Window", Table = Cfg.Block, Key = "RecoveryWindow", Min = 0.2, Max = 1.5, Step = 0.05, Suffix = " s" })

    T:Section("Auto Parry / Dodge")
    UI.Elements.AutoDodge = T:Toggle({ Name = "Auto Dodge", Table = Cfg.Dodge, Key = "Enabled",
        Callback = function(v) Combat.onFeatureToggle("Auto Dodge", v) end })
    UI.Elements.DodgeBind = T:Keybind({ Name = "Toggle Bind", Table = Cfg.Dodge, Key = "Bind", AllowNone = true })
    UI.Elements.DodgeLead = T:Slider({ Name = "Dodge Lead", Table = Cfg.Dodge, Key = "Lead", Min = 0, Max = 0.3, Step = 0.01, Suffix = " s" })
    UI.Elements.DodgeCd = T:Slider({ Name = "Cooldown", Table = Cfg.Dodge, Key = "Cooldown", Min = 0.2, Max = 4, Step = 0.05, Suffix = " s" })
    UI.Elements.DodgeTap = T:Slider({ Name = "Tap Duration", Table = Cfg.Dodge, Key = "Tap", Min = 0.02, Max = 0.3, Step = 0.01, Suffix = " s" })
    UI.Elements.DodgeFb = T:Toggle({ Name = "Fallback to Auto Block", Table = Cfg.Dodge, Key = "Fallback" })

    T:Section("Detection")
    UI.Elements.MaxDist = T:Slider({ Name = "Max Distance", Table = Cfg.Detect, Key = "MaxDistance", Min = 5, Max = 40, Step = 1, Suffix = " studs" })
    UI.Elements.Facing = T:Toggle({ Name = "Facing Check", Table = Cfg.Detect, Key = "FacingCheck" })
    UI.Elements.FacingTh = T:Slider({ Name = "Facing Threshold", Table = Cfg.Detect, Key = "FacingThreshold", Min = -0.2, Max = 0.9, Step = 0.05 })
    UI.Elements.PingComp = T:Toggle({ Name = "Ping Compensation", Table = Cfg.Detect, Key = "PingComp" })
    UI.Elements.Filter = T:Dropdown({ Name = "Animation Filter", Table = Cfg.Detect, Key = "Filter", Options = { "All", "Learned" } })

    T:Section("Tools")
    T:Button({ Name = "Test Block", Callback = Combat.testBlock })
    T:Button({ Name = "Test Dodge", Callback = Combat.testDodge })
    UI.Elements.Learn = T:Toggle({ Name = "Learn Mode (log to F9 console)", Table = State, Key = "Learn",
        Callback = function(v)
            Combat.LearnTracks = {}
            UI.Toast("Learn mode: " .. (v and "ON" or "OFF"), v and "on" or "off")
            if v then log("Learn mode ON - take hits; animation id / length / speed / priority / distance / hit moment are logged.") end
        end })
    local learnedLbl = T:Label("Learned attacks: 0")
    function UI.UpdateLearned()
        local n = 0
        for _ in pairs(Cfg.Learned) do n += 1 end
        learnedLbl:SetText("Learned attacks: " .. n)
    end
    UI.Elements.LearnedLbl = { Refresh = UI.UpdateLearned }
    T:Button({ Name = "Reset Learned Timings", Callback = function()
        Cfg.Learned = {}
        UI.UpdateLearned()
        UI.Toast("Learned timings cleared", "info")
    end })

    ---------------------------------------------------------------- SETTINGS
    local S = UI.AddTab("Settings")
    S:Section("Input")
    UI.Elements.InMode = S:Dropdown({ Name = "Input Mode", Table = Cfg.Input, Key = "Mode", Options = { "Auto", "Key", "Remote" },
        Callback = function() Input.releaseAll() end })
    UI.Elements.InMethod = S:Dropdown({ Name = "Key Method", Table = Cfg.Input, Key = "Method", Options = Input.methods,
        Callback = function() Input.releaseAll() end })
    UI.Elements.MaxHold = S:Slider({ Name = "Max Hold (anti-stuck)", Table = Cfg.Input, Key = "MaxHold", Min = 1, Max = 10, Step = 0.5, Suffix = " s" })

    S:Section("Keys")
    UI.Elements.BlockKey = S:Keybind({ Name = "Block Key (in-game)", Table = Cfg.Input, Key = "BlockKey",
        Callback = function() Input.releaseAll() end })
    UI.Elements.DodgeKey = S:Keybind({ Name = "Dodge Key (in-game)", Table = Cfg.Input, Key = "DodgeKey",
        Callback = function() Input.releaseAll() end })
    UI.Elements.MenuKey = S:Keybind({ Name = "Menu Hotkey", Table = Cfg.Input, Key = "MenuKey" })

    S:Section("Config")
    local cfgLbl = S:Label(ConfigIO.available() and ("File: " .. ConfigIO.path()) or "File API unavailable in this executor")
    S:Button({ Name = "Save Config", Callback = ConfigIO.save })
    S:Button({ Name = "Load Config", Callback = ConfigIO.load })

    S:Section("Script")
    S:Button({ Name = "UNLOAD SCRIPT", Danger = true, Callback = function() env.RevengersX.Unload() end })

    ---------------------------------------------------------------- THEME
    local H = UI.AddTab("Theme")
    H:Section("Accent")
    local presets = {
        { "Crimson", "E5334F" }, { "Violet", "8B5CF6" }, { "Cyan", "22D3EE" },
        { "Emerald", "34D399" }, { "Amber", "F59E0B" }, { "Pink", "EC4899" },
    }
    local pr = row(H, 44)
    local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = pr }, {
        new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10),
            VerticalAlignment = Enum.VerticalAlignment.Center }),
        new("UIPadding", { PaddingLeft = UDim.new(0, 12) }),
    })
    for _, p in ipairs(presets) do
        local c = fromHex(p[2])
        local b = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(28, 28), BackgroundColor3 = c, Parent = holder },
            { corner(14), uiStroke(P.Stroke, 1) })
        b.MouseEnter:Connect(function() tween(b, TweenInfo.new(0.12), { Size = UDim2.fromOffset(32, 32) }) end)
        b.MouseLeave:Connect(function() tween(b, TweenInfo.new(0.12), { Size = UDim2.fromOffset(28, 28) }) end)
        b.MouseButton1Click:Connect(function() UI.SetAccent(c); UI.Toast("Accent: " .. p[1], "info") end)
    end

    local hex = H:TextBox({ Name = "Custom HEX", Placeholder = "#RRGGBB", Default = "#" .. Cfg.Theme.Accent, Callback = function(txt, box)
        local c = fromHex(txt)
        if c then UI.SetAccent(c) else UI.Toast("Invalid HEX", "err"); box.Text = "#" .. Cfg.Theme.Accent end
    end })
    local rgb = { R = 0, G = 0, B = 0 }
    local function fromSliders() UI.SetAccent(Color3.fromRGB(rgb.R, rgb.G, rgb.B), true); hex:SetText("#" .. Cfg.Theme.Accent) end
    local sR = H:Slider({ Name = "Red", Table = rgb, Key = "R", Min = 0, Max = 255, Step = 1, Callback = fromSliders })
    local sG = H:Slider({ Name = "Green", Table = rgb, Key = "G", Min = 0, Max = 255, Step = 1, Callback = fromSliders })
    local sB = H:Slider({ Name = "Blue", Table = rgb, Key = "B", Min = 0, Max = 255, Step = 1, Callback = fromSliders })
    function UI.SyncTheme()
        local c = UI.Accent
        rgb.R, rgb.G, rgb.B = math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255)
        sR.Refresh(); sG.Refresh(); sB.Refresh()
        hex:SetText("#" .. Cfg.Theme.Accent)
    end

    H:Section("Window")
    UI.Elements.AnimTitle = H:Toggle({ Name = "Animated Title Gradient", Table = Cfg.Theme, Key = "AnimateTitle" })
    UI.Elements.Transp = H:Slider({ Name = "Window Transparency", Table = Cfg.Theme, Key = "Transparency", Min = 0, Max = 0.6, Step = 0.01,
        Callback = function(v) if State.MenuOpen then UI.Main.GroupTransparency = v end end })

    UI.UpdateLearned()
end

--==============================================================================
-- 7. LIFECYCLE
--==============================================================================
local function Unload()
    if State.Unloaded then return end
    State.Unloaded = true
    Block.holdUntil = 0
    pcall(Input.releaseAll)                       -- release held keys first
    for plr in pairs(Combat.Hooks) do Combat.unhookPlayer(plr) end
    MainMaid:Destroy()                            -- connections, loops, GUI
    Combat.clear()
    if env.RevengersX and env.RevengersX.Unload == Unload then env.RevengersX = nil end
    log("Unloaded.")
end
env.RevengersX = { Unload = Unload, Cfg = Cfg }

local function init()
    Input.normalize()
    local saved = fromHex(Cfg.Theme.Accent)
    if saved then UI.Accent = saved end

    UI.Build()
    buildTabs()
    UI.SetAccent(UI.Accent)

    -- Players
    for _, p in ipairs(Players:GetPlayers()) do Combat.hookPlayer(p) end
    MainMaid:Add(Players.PlayerAdded:Connect(Combat.hookPlayer))
    MainMaid:Add(Players.PlayerRemoving:Connect(function(p)
        if p == LP then Input.releaseAll() end
        Combat.unhookPlayer(p)
    end))

    -- Local character
    if LP.Character then hookLocalCharacter(LP.Character) end
    MainMaid:Add(LP.CharacterAdded:Connect(hookLocalCharacter))
    MainMaid:Add(LP.CharacterRemoving:Connect(function()
        Block.holdUntil = 0
        Input.releaseAll()
    end))

    -- Focus lost -> never leave a key stuck
    MainMaid:Add(UserInputService.WindowFocusReleased:Connect(function()
        Block.holdUntil = 0
        Input.releaseAll()
    end))

    -- Hotkeys: key capture > menu > feature binds
    MainMaid:Add(UserInputService.InputBegan:Connect(function(input, processed)
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        if UI.CaptureFn then
            local f = UI.CaptureFn
            UI.CaptureFn = nil
            f(input.KeyCode)
            return
        end
        if processed then return end
        local name = input.KeyCode.Name
        if name == Cfg.Input.MenuKey then UI.ToggleMenu() return end
        if name == Cfg.Input.BlockKey or name == Cfg.Input.DodgeKey then return end -- avoid bind/in-game key conflicts
        if name == Cfg.Block.Bind then UI.Elements.AutoBlock:Set(not Cfg.Block.Enabled)
        elseif name == Cfg.Dodge.Bind then UI.Elements.AutoDodge:Set(not Cfg.Dodge.Enabled) end
    end))

    -- Main combat loop
    local warned = false
    MainMaid:Add(RunService.Heartbeat:Connect(function()
        if State.Unloaded then return end
        local ok, err = pcall(Combat.step, os.clock())
        if not ok and not warned then warned = true; log("combat step error: %s", tostring(err)) end
    end))

    task.delay(0.1, function() UI.SetVisible(true) end)
    task.delay(0.6, function()
        UI.Toast("Revengers X loaded - " .. Cfg.Input.MenuKey .. " toggles menu", "info")
        if not Input.keyAvailable() then UI.Toast("No key backend - using Remote mode", "err") end
    end)
    log("Loaded. Menu key: %s | key methods: %s", Cfg.Input.MenuKey, table.concat(Input.methods(), "/"))
end

local ok, err = pcall(init)
if not ok then
    warn("[RevengersX] init failed: " .. tostring(err))
    Unload()
end
