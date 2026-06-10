-- VV AutoParry — Matcha EXTERNAL (release build, M2-only)
-- Calibrated: Gelum, Scorpion Hollow, Giant Dragonfly. Tune timing via your ping (PING_MS / AUTO_PING).
-- _G.VV_AUTOPARRY = {
--     LOCK_KEY    = "C",     -- Change it to whatever keybind you want
--     PING_MS     = 0,       -- manual ping compensation (ms) if auto ping isnt that good for you
--     AUTO_PING   = true,    -- autoparry adapts off your ping; falls back to PING_MS
--     SHOW_RADIUS = true,
--     RADIUS_SIZE = nil,     -- optional: set a number (e.g. 45) to force a custom radius.
--                            --           when set, the auto Scorpion Hollow / Giant Dragonfly
--                            --           radius boost is disabled and your value is always used.
-- }
--
-- Radius behavior (when RADIUS_SIZE is NOT set):
--   * locked onto Scorpion Hollow or Giant Dragonfly -> radius grows (BIG_RANGE = 32)
--   * any other enemy / unlocked                      -> default radius (DEFAULT_RANGE = 14)
-- loadstring(game:HttpGet("GITHUBLINK"))()

local Players   = game:GetService("Players")
local Workspace = workspace or game:GetService("Workspace")
local LP    = Players.LocalPlayer
local Mouse = LP:GetMouse()

local INSTANCE_KEY = "__VV_AUTOPARRY_MATCHA_STATE"
local old = _G and _G[INSTANCE_KEY]
if old then
    old.running = false
    if type(old.cleanup) == "function" then pcall(old.cleanup) end
end
local script_state = { running = true, drawings = {} }
if _G then _G[INSTANCE_KEY] = script_state end

local function resolve_key(key, fallback)
    if type(key) == "string" and #key >= 1 then
        return key:upper():sub(1,1):byte()
    end
    return fallback:byte()
end

local USER = (_G and _G.VV_AUTOPARRY) or {}
local function C(key, default)
    local v = USER[key]
    if v ~= nil then return v end
    return default
end

local LOCK_KEY    = resolve_key(C("LOCK_KEY", "C"), "C")
local PING_MS     = C("PING_MS", 0)
local AUTO_PING   = C("AUTO_PING", true)
local SHOW_RADIUS = C("SHOW_RADIUS", true)
local RADIUS_SIZE = C("RADIUS_SIZE", nil) -- set a number to force a custom radius (disables auto-scaling)
local PING_LEAD   = math.max(0, PING_MS) / 1000

local DEBUG       = true

-- Radius config -------------------------------------------------------------
-- DEFAULT_RANGE : normal detection/visual radius.
-- BIG_RANGE     : larger radius used while locked onto a Scorpion Hollow or Giant Dragonfly.
-- RADIUS_SIZE   : if the user sets this (positive number), it ALWAYS wins and the
--                 scorpion/dragonfly auto-enlarge effect is disabled for them.
local DEFAULT_RANGE = 14
local BIG_RANGE     = 32
local USE_CUSTOM_RADIUS = (type(RADIUS_SIZE) == "number" and RADIUS_SIZE > 0)
if USE_CUSTOM_RADIUS then DEFAULT_RANGE = RADIUS_SIZE end

local RANGE       = DEFAULT_RANGE
local RANGE_SQ    = RANGE * RANGE
local LivingFolderName = "Living"

local CLASH_EFFECT   = "CanClash"
local SIGNAL_EFFECT  = "AttackingSignal"
local SIGNAL_TO_HIT  = 0.535
local CLASH_TO_HIT   = 0.083
local BACKUP_AFTER_SIGNAL = SIGNAL_TO_HIT - CLASH_TO_HIT
local PARRY_HOLD     = 0.28
local PARRY_COOLDOWN = 0.12
local BACKUP_ENABLED = true

local MOVES = {
    ["Heavy Kick"]                  = { action = "parry", windup = 0.554 },
    ["False Cutter"]                = { action = "block", windup = 1.222, hold = 0.50 },
    ["ScorpionHollow_PoisonBreath"] = { action = "block", windup = 1.382, hold = 0.55 },
    ["Roar"]                        = { action = "block", windup = 0.30,  hold = 0.80 },
    ["ScorpionPoison"]              = { action = "block", windup = 0.25,  hold = 0.70 },
    ["GiantDragonfly_Slam"]         = { action = "block", windup = 0.753, hold = 0.45 },
    ["GiantDragonfly_Tailwhip"]     = { action = "block", windup = 1.457, hold = 0.45 },
    ["GiantDragonfly_Grab"]         = { action = "block", windup = 1.493, hold = 0.45 },
}
local MOVE_COOLDOWN  = 0.45
local BLOCK_LEAD     = 0.22
local LIGHT_PARRY    = true
local LIGHT_WINDUP   = 0.60
local ATTACK_EFFECT  = "Attacking"

local v3 = Vector3.new
local color_green = Color3.new(0,1,0)
local color_red   = Color3.new(1,0,0)
local color_cyan  = Color3.new(0,1,1)
local segs = 16

local function track(o) script_state.drawings[#script_state.drawings+1]=o; return o end
local function remove_drawing(o)
    if not o then return end
    pcall(function() o.Visible=false end)
    if type(o.Remove)=="function" then pcall(function() o:Remove() end)
    elseif type(o.Destroy)=="function" then pcall(function() o:Destroy() end) end
end
script_state.cleanup = function()
    for i=1,#script_state.drawings do remove_drawing(script_state.drawings[i]) end
    script_state.drawings = {}
end

local circle = {}
local enemy_label = nil
if SHOW_RADIUS then
    for i=1,segs do local l=track(Drawing.new("Line")); l.Thickness=1; l.Visible=false; circle[i]=l end
    enemy_label = track(Drawing.new("Text"))
    enemy_label.Outline=true; enemy_label.Center=true; enemy_label.Size=14; enemy_label.Color=color_red; enemy_label.Visible=false
end

local function safe(fn,fb) local ok,r=pcall(fn); if ok then return r end return fb end
if type(setrobloxinput)=="function" then safe(function() setrobloxinput(true) end) end
local last_dbg=0
local function dbg(msg, force)
    if not DEBUG or type(notify)~="function" then return end
    local now=tick()
    if not force and now-last_dbg<0.4 then return end
    last_dbg=now
    safe(function() notify(tostring(msg), "VV AutoParry", 2) end)
end
local function get_hrp(m) return m and m:FindFirstChild("HumanoidRootPart") end
local function my_char() return LP and LP.Character end
local function my_root() return get_hrp(my_char()) end
local function living_folder() return Workspace and Workspace:FindFirstChild(LivingFolderName) end
local function status_folder(m) return m and m:FindFirstChild("Status") end
local function cooldowns_folder(m) return m and m:FindFirstChild("Cooldowns") end

local last_ping_poll = 0
local function update_ping()
    if not AUTO_PING then return end
    local now = tick()
    if now - last_ping_poll < 1 then return end
    last_ping_poll = now
    local p = safe(function()
        local v = LP:GetNetworkPing()
        if type(v) == "number" then return v * 1000 end
        return nil
    end)
    if not p then
        p = safe(function()
            local stats = game:GetService("Stats")
            return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
    end
    if type(p) == "number" and p >= 0 then
        PING_LEAD = math.max(0, math.max(PING_MS, p)) / 1000
    end
end

local function is_enemy(m)
    if not m or not m.Parent then return false end
    if m==my_char() then return false end
    if m.Name==LP.Name then return false end
    return get_hrp(m)~=nil
end
local function dist_sq(a,b) local dx,dy,dz=a.X-b.X,a.Y-b.Y,a.Z-b.Z; return dx*dx+dy*dy+dz*dz end
local function display_name(m)
    if not m then return "enemy" end
    if type(m.Name)=="string" and #m.Name>0 then return m.Name end
    return "enemy"
end

-- Scorpion Hollow / Giant Dragonfly get a larger radius when locked on.
local function is_big_radius_enemy(m)
    if not m then return false end
    local n = tostring(m.Name):lower()
    return (n:find("scorpion") ~= nil) or (n:find("dragonfly") ~= nil)
end

-- Recompute RANGE/RANGE_SQ based on the current lock target.
-- Users with a custom RADIUS_SIZE always keep their value (no auto-scaling).
local function apply_range_for_target(tgt)
    local desired
    if USE_CUSTOM_RADIUS then
        desired = RADIUS_SIZE
    elseif tgt and is_big_radius_enemy(tgt) then
        desired = BIG_RANGE
    else
        desired = DEFAULT_RANGE
    end
    if desired ~= RANGE then
        RANGE = desired
        RANGE_SQ = RANGE * RANGE
    end
end

local function candidate_targets()
    local list, seen = {}, {}
    local folder=living_folder()
    if folder then
        for _,m in ipairs(folder:GetChildren()) do
            if not seen[m] then seen[m]=true; list[#list+1]=m end
        end
    end
    for _,pl in ipairs(Players:GetPlayers()) do
        local ch=pl.Character
        if ch and not seen[ch] then seen[ch]=true; list[#list+1]=ch end
    end
    return list
end

local function closest_to_cursor()
    local mr=my_root(); if not mr then return nil end
    local mx,my=Mouse.X,Mouse.Y
    local bs,bsd,bw,bwd=nil,math.huge,nil,math.huge
    for _,m in ipairs(candidate_targets()) do
        if is_enemy(m) then
            local r=get_hrp(m)
            if r then
                local wd=dist_sq(r.Position,mr.Position)
                if wd<bwd then bwd=wd; bw=m end
                local sp,on=WorldToScreen(r.Position)
                if on then local dx,dy=sp.X-mx,sp.Y-my; local sd=dx*dx+dy*dy; if sd<bsd then bsd=sd; bs=m end end
            end
        end
    end
    return bs or bw
end

local function has_effect(m,name)
    local s=status_folder(m); return s~=nil and s:FindFirstChild(name)~=nil
end
local function attack_present(m,name)
    local cd=cooldowns_folder(m)
    if cd and cd:FindFirstChild(name) then return true end
    local s=status_folder(m)
    if s and s:FindFirstChild(name) then return true end
    return false
end
local function self_has_effect(name)
    local s=status_folder(my_char()); return s~=nil and s:FindFirstChild(name)~=nil
end
local function enemy_attacking(m)
    return has_effect(m,"Attacking") or has_effect(m,"AttackingCanBlock") or has_effect(m,"AttackingSignal")
end
local function clash_state(m)
    if has_effect(m, CLASH_EFFECT) then return true end
    return self_has_effect(CLASH_EFFECT) and enemy_attacking(m)
end

local blocking = false
local function m2_down() if type(mouse2press)=="function" then safe(mouse2press) elseif type(mousepress)=="function" then safe(function() mousepress(2) end) end end
local function m2_up()   if type(mouse2release)=="function" then safe(mouse2release) elseif type(mouserelease)=="function" then safe(function() mouserelease(2) end) end end
local function set_block(s) if s==blocking then return end blocking=s; if s then m2_down() else m2_up() end end

local parry_busy, last_parry_time = false, 0
local function tap_parry(reason)
    if parry_busy then return false end
    if tick()-last_parry_time < PARRY_COOLDOWN then return false end
    parry_busy=true; last_parry_time=tick()
    dbg("parry ("..tostring(reason)..")")
    task.spawn(function()
        if not script_state.running then parry_busy=false return end
        set_block(true); task.wait(PARRY_HOLD); set_block(false)
        parry_busy=false
    end)
    return true
end

local function hide_visuals()
    if not SHOW_RADIUS then return end
    for i=1,segs do circle[i].Visible=false end
    if enemy_label then enemy_label.Visible=false end
end
local function draw_visuals(mr,tr,target,mode)
    if not SHOW_RADIUS then return end
    local step=6.283185307179586/segs
    local col = (mode=="timed" and color_cyan) or (target and color_green or color_red)
    local cx,cy,cz=mr.Position.X,mr.Position.Y-3,mr.Position.Z
    local pts,vis={},{}
    for i=0,segs do local a=i*step; local sp,on=WorldToScreen(v3(cx+math.cos(a)*RANGE,cy,cz+math.sin(a)*RANGE)); pts[i]=sp; vis[i]=on end
    for i=1,segs do local l=circle[i]
        if vis[i-1] and vis[i] then l.From=Vector2.new(pts[i-1].X,pts[i-1].Y); l.To=Vector2.new(pts[i].X,pts[i].Y); l.Color=col; l.Visible=true
        else l.Visible=false end
    end
    if target and tr and enemy_label then
        local lp,on=WorldToScreen(tr.Position+v3(0,4,0))
        if on then enemy_label.Text=display_name(target); enemy_label.Position=Vector2.new(lp.X,lp.Y); enemy_label.Visible=true else enemy_label.Visible=false end
    elseif enemy_label then enemy_label.Visible=false end
end

local target=nil
local prev_clash=false
local prev_signal=false
local prev_attacking=false
local backup_time=0
local backup_armed=false
local move_prev={}
local move_last={}
local parry_fire={}
local block_start=0
local block_end=0

local function reset_detection()
    prev_clash=false; prev_signal=false; backup_time=0; backup_armed=false
    move_prev={}; move_last={}; parry_fire={}
    block_start=0; block_end=0; prev_attacking=false
end

dbg("loaded — hover an enemy and press the lock key", true)
local last_lock=false
while script_state.running do
    task.wait()
    update_ping()

    local lock_now = type(iskeypressed)=="function" and iskeypressed(LOCK_KEY) or false
    if lock_now and not last_lock then
        if target then target=nil; set_block(false); reset_detection(); dbg("unlocked", true)
        else target=closest_to_cursor(); reset_detection(); dbg(target and ("locked: "..display_name(target)) or "no enemy found near cursor", true) end
    end
    last_lock=lock_now

    apply_range_for_target(target)

    local mr=my_root()
    if not mr then
        target=nil; set_block(false); reset_detection(); hide_visuals()
    else
        local tr=nil
        local mode=nil
        if target and target.Parent and is_enemy(target) then
            tr=get_hrp(target)
            if tr then
                local in_range = dist_sq(tr.Position,mr.Position) <= RANGE_SQ
                local now=tick()

                for nm,info in pairs(MOVES) do
                    local present = attack_present(target, nm)
                    if in_range and present and not move_prev[nm]
                       and (now - (move_last[nm] or -999)) > MOVE_COOLDOWN then
                        move_last[nm] = now
                        if info.action == "block" then
                            block_start = now + (info.windup - BLOCK_LEAD - PING_LEAD)
                            block_end   = block_start + (info.hold or 0.5)
                        else
                            parry_fire[nm] = now + (info.windup - CLASH_TO_HIT - PING_LEAD)
                        end
                    end
                    move_prev[nm] = present
                end

                if LIGHT_PARRY then
                    local attacking_now = has_effect(target, ATTACK_EFFECT)
                    if in_range and attacking_now and not prev_attacking then
                        parry_fire["__light"] = now + (LIGHT_WINDUP - CLASH_TO_HIT - PING_LEAD)
                    end
                    prev_attacking = attacking_now
                end

                for nm,t in pairs(parry_fire) do
                    if t and now >= t then
                        parry_fire[nm] = nil
                        if in_range then tap_parry("timed"); mode="timed" end
                    end
                end

                local block_active=false
                if (block_start ~= 0) and now >= block_start and now <= block_end and in_range then
                    block_active = true
                elseif (block_start ~= 0) and now > block_end then
                    block_start = 0; block_end = 0
                end

                if block_active then set_block(true); mode="timed" end

                if not block_active and in_range then
                    local clash_now  = clash_state(target)
                    local signal_now = has_effect(target, SIGNAL_EFFECT)
                    if clash_now and not prev_clash then tap_parry("clash") end
                    if BACKUP_ENABLED and signal_now and not prev_signal then
                        backup_time=now+(BACKUP_AFTER_SIGNAL-PING_LEAD); backup_armed=true
                    end
                    if backup_armed and now>=backup_time then
                        if not parry_busy and has_effect(target, SIGNAL_EFFECT) then tap_parry("backup") end
                        backup_armed=false
                    end
                    prev_clash=clash_now; prev_signal=signal_now
                else
                    prev_clash  = clash_state(target)
                    prev_signal = has_effect(target, SIGNAL_EFFECT)
                end

                if not block_active and not parry_busy then set_block(false) end
            end
        else
            target=nil; reset_detection()
            if not parry_busy then set_block(false) end
        end

        draw_visuals(mr,tr,target,mode)
    end
end

set_block(false); hide_visuals(); script_state.cleanup()
if _G and _G[INSTANCE_KEY]==script_state then _G[INSTANCE_KEY]=nil end
