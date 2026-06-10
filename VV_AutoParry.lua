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
local LOCK_KEY      = resolve_key(C("LOCK_KEY", "C"), "C")
local PING_FLOOR_MS = C("PING_FLOOR_MS", 0)
local PING_DEFAULT  = C("PING_DEFAULT", 50)
local SHOW_RADIUS   = C("SHOW_RADIUS", true)
local SHOW_PING     = C("SHOW_PING", true)
local RADIUS_SIZE   = C("RADIUS_SIZE", nil)
local JITTER_MULT   = C("JITTER_MULT", 1.15)
local DODGE_KEY     = C("DODGE_KEY", 0x51)
local DEBUG = true
local ping_raw_ms     = PING_DEFAULT
local ping_smooth_ms  = PING_DEFAULT
local ping_jitter_ms  = 0
local ping_initialized = false
local PING_EMA_ALPHA  = 0.3
local DEFAULT_RANGE = 14
local BIG_RANGE     = 30
local HUGE_RANGE    = 35
local USE_CUSTOM_RADIUS = (type(RADIUS_SIZE) == "number" and RADIUS_SIZE > 0)
if USE_CUSTOM_RADIUS then DEFAULT_RANGE = RADIUS_SIZE end
local RANGE       = DEFAULT_RANGE
local ACTION_LOCKOUT = 0.50
local RANGE_SQ    = RANGE * RANGE
local LivingFolderName = "Living"
local CLASH_EFFECT   = "CanClash"
local SIGNAL_EFFECT  = "AttackingSignal"
local SIGNAL_TO_HIT  = 0.565
local CLASH_TO_HIT   = 0.093
local BACKUP_AFTER_SIGNAL = SIGNAL_TO_HIT - CLASH_TO_HIT
local PARRY_HOLD     = 0.28
local PARRY_COOLDOWN = 0.30
local BACKUP_ENABLED = true
local MOVES = {
    ["Heavy Kick"] = {
        action = "dodge", windup = 0.555, dodge_dir = "back",
    },
    ["False Cutter"] = {
        action = "dodge", windup = 0.735, dodge_dir = "back",
        signal = "FalseCutterStart", signal_windup = 1.48,
    },
    ["Overhead Strike"] = {
        action = "dodge", windup = 1.10, dodge_dir = "back",
    },
    ["Skyscraper"] = {
        action = "dodge", windup = 0.80, dodge_dir = "back",
    },
    ["GelumAOE"] = {
        action = "dodge", windup = 2.00, dodge_dir = "back",
    },
    ["GelumMeteor"] = {
        action = "block", windup = 0.552, hold = 0.50,
    },
    ["Cyclone"] = {
        action = "block", windup = 0.670, hold = 0.60,
        signal = "MoveActive", signal_windup = 0.670,
    },
    ["Running Attack"] = {
        action = "parry", windup = 0.670,
    },
    ["ScorpionHollow_PoisonBreath"] = { action = "block", windup = 1.382, hold = 0.55 },
    ["Roar"]                        = { action = "block", windup = 0.30,  hold = 0.80 },
    ["ScorpionPoison"]              = { action = "block", windup = 0.25,  hold = 0.70 },
    ["GiantDragonfly_Slam"]         = { action = "block", windup = 0.753, hold = 0.45 },
    ["GiantDragonfly_Tailwhip"]     = { action = "block", windup = 1.457, hold = 0.45 },
    ["GiantDragonfly_Grab"]         = { action = "dodge", windup = 1.493, dodge_dir = "back" },
}
local SIGNAL_MOVES = {}
for nm, info in pairs(MOVES) do
    if info.signal then
        SIGNAL_MOVES[info.signal] = { name = nm, info = info }
    end
end
local MOVE_COOLDOWN  = 0.45
local BLOCK_LEAD     = 0.20
local LIGHT_PARRY    = true
local LIGHT_WINDUP   = 0.565
local ATTACK_EFFECT  = "Attacking"
local DODGE_DURATION = 0.18
local DODGE_COOLDOWN = 0.40
local v3 = Vector3.new
local color_green  = Color3.new(0,1,0)
local color_red    = Color3.new(1,0,0)
local color_cyan   = Color3.new(0,1,1)
local color_orange = Color3.new(1,0.6,0)
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
local ping_label = nil
local action_label = nil
if SHOW_RADIUS then
    for i=1,segs do local l=track(Drawing.new("Line")); l.Thickness=1; l.Visible=false; circle[i]=l end
    enemy_label = track(Drawing.new("Text"))
    enemy_label.Outline=true; enemy_label.Center=true; enemy_label.Size=14; enemy_label.Color=color_red; enemy_label.Visible=false
    action_label = track(Drawing.new("Text"))
    action_label.Outline=true; action_label.Center=true; action_label.Size=12; action_label.Color=color_orange; action_label.Visible=false
end
if SHOW_PING then
    ping_label = track(Drawing.new("Text"))
    ping_label.Outline=true; ping_label.Center=false; ping_label.Size=13
    ping_label.Color=Color3.new(1,1,1); ping_label.Position=Vector2.new(10,10); ping_label.Visible=true
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
local function read_ping_raw()
    local p = safe(function()
        local v = LP:GetNetworkPing()
        if type(v) == "number" and v > 0 then return v * 1000 end
        return nil
    end)
    if not p or p <= 0 then
        p = safe(function()
            local stats = game:GetService("Stats")
            return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
    end
    if type(p) == "number" and p > 0 then
        return p
    end
    return ping_initialized and ping_raw_ms or PING_DEFAULT
end
local function update_ping()
    local now = tick()
    if now - last_ping_poll < 0.5 then return end
    last_ping_poll = now
    local raw = read_ping_raw()
    ping_raw_ms = raw
    if not ping_initialized then
        ping_smooth_ms = raw
        ping_initialized = true
    else
        ping_smooth_ms = ping_smooth_ms + PING_EMA_ALPHA * (raw - ping_smooth_ms)
    end
    local jitter = math.abs(raw - ping_smooth_ms)
    ping_jitter_ms = ping_jitter_ms + PING_EMA_ALPHA * (jitter - ping_jitter_ms)
end
local function get_ping_lead()
    local compensated = ping_smooth_ms * JITTER_MULT + ping_jitter_ms
    compensated = math.max(compensated, PING_FLOOR_MS)
    return compensated / 1000
end
local function update_ping_hud()
    if not SHOW_PING or not ping_label then return end
    local lead = get_ping_lead()
    ping_label.Text = ("PING %dms (smooth:%d jit:%d comp:%d)"):format(
        math.floor(ping_raw_ms + 0.5),
        math.floor(ping_smooth_ms + 0.5),
        math.floor(ping_jitter_ms + 0.5),
        math.floor(lead * 1000 + 0.5))
    local ratio = ping_raw_ms / 150
    if ratio > 1 then ratio = 1 end
    ping_label.Color = Color3.new(ratio, 1 - ratio * 0.7, ratio < 0.5 and 1 - ratio or 0)
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
local BOSS_RANGES = {
    gelum      = HUGE_RANGE,
    scorpion   = BIG_RANGE,
    dragonfly  = BIG_RANGE,
}
local function get_enemy_range(m)
    if not m then return DEFAULT_RANGE end
    local n = tostring(m.Name):lower()
    for pattern, range in pairs(BOSS_RANGES) do
        if n:find(pattern) then return range end
    end
    return DEFAULT_RANGE
end
local function apply_range_for_target(tgt)
    local desired
    if USE_CUSTOM_RADIUS then
        desired = RADIUS_SIZE
    else
        desired = get_enemy_range(tgt)
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
    dbg("PARRY ("..tostring(reason)..")")
    task.spawn(function()
        if not script_state.running then parry_busy=false return end
        set_block(true); task.wait(PARRY_HOLD); set_block(false)
        parry_busy=false
    end)
    return true
end
local dodge_busy, last_dodge_time = false, 0
local function tap_dodge(reason, direction)
    if dodge_busy then return false end
    if tick()-last_dodge_time < DODGE_COOLDOWN then return false end
    dodge_busy=true; last_dodge_time=tick()
    dbg("DODGE ("..tostring(reason)..")")
    task.spawn(function()
        if not script_state.running then dodge_busy=false return end
        local dir_key = 0x53
        if direction == "left" then dir_key = 0x41
        elseif direction == "right" then dir_key = 0x44
        elseif direction == "forward" then dir_key = 0x57 end
        if type(keypress)=="function" then
            safe(function() keypress(dir_key) end)
            safe(function() keypress(DODGE_KEY) end)
            task.wait(DODGE_DURATION)
            safe(function() keyrelease(DODGE_KEY) end)
            safe(function() keyrelease(dir_key) end)
        end
        dodge_busy=false
    end)
    return true
end
local last_action_text = ""
local last_action_time = 0
local function show_action(text)
    last_action_text = text
    last_action_time = tick()
end
local function hide_visuals()
    if not SHOW_RADIUS then return end
    for i=1,segs do circle[i].Visible=false end
    if enemy_label then enemy_label.Visible=false end
    if action_label then action_label.Visible=false end
end
local function draw_visuals(mr,tr,target,mode)
    if not SHOW_RADIUS then return end
    local step=6.283185307179586/segs
    local col = (mode=="dodge" and color_orange) or (mode=="timed" and color_cyan) or (target and color_green or color_red)
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
    if action_label then
        if tick() - last_action_time < 1.5 and target and tr then
            local lp,on=WorldToScreen(tr.Position+v3(0,5.5,0))
            if on then action_label.Text=last_action_text; action_label.Position=Vector2.new(lp.X,lp.Y); action_label.Visible=true
            else action_label.Visible=false end
        else action_label.Visible=false end
    end
end
local target=nil
local prev_clash=false
local prev_signal=false
local prev_attacking=false
local backup_time=0
local backup_armed=false
local move_prev={}
local move_last={}
local signal_prev={}
local parry_fire={}
local dodge_fire={}
local block_start=0
local block_end=0
local function reset_detection()
    prev_clash=false; prev_signal=false; backup_time=0; backup_armed=false
    move_prev={}; move_last={}; signal_prev={}; parry_fire={}; dodge_fire={}
    block_start=0; block_end=0; prev_attacking=false
end
local last_action_time = 0
local function action_locked(now)
    return (now - last_action_time) < ACTION_LOCKOUT
end
local function execute_move(nm, info, now, pl)
    if action_locked(now) then return end
    last_action_time = now
    parry_fire = {}
    dodge_fire = {}
    backup_armed = false
    if info.action == "dodge" then
        local delay = info.windup - 0.20 - pl
        if delay < 0.05 then delay = 0.05 end
        dodge_fire[nm] = now + delay
        show_action(">> DODGE: " .. nm)
    elseif info.action == "block" then
        block_start = now + (info.windup - BLOCK_LEAD - pl)
        block_end   = block_start + (info.hold or 0.5)
        show_action(">> BLOCK: " .. nm)
    else
        parry_fire[nm] = now + (info.windup - CLASH_TO_HIT - pl)
        show_action(">> PARRY: " .. nm)
    end
end
local function classify_and_respond(m, now, pl)
    if has_effect(m, CLASH_EFFECT) then
        return "parry"
    end
    if has_effect(m, "AnimArmor") and has_effect(m, "Attacking") then
        return "dodge"
    end
    if has_effect(m, "AttackingCanBlock") then
        return "block"
    end
    return "parry"
end
dbg("VV AutoParry v2.1 loaded", true)
local last_lock=false
while script_state.running do
    task.wait()
    update_ping()
    update_ping_hud()
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
                local pl = get_ping_lead()
                for nm,info in pairs(MOVES) do
                    local present = attack_present(target, nm)
                    if in_range and present and not move_prev[nm]
                       and (now - (move_last[nm] or -999)) > MOVE_COOLDOWN then
                        move_last[nm] = now
                        execute_move(nm, info, now, pl)
                    end
                    move_prev[nm] = present
                end
                for sig_name, sig_data in pairs(SIGNAL_MOVES) do
                    local present = has_effect(target, sig_name)
                    if in_range and present and not signal_prev[sig_name]
                       and (now - (move_last[sig_data.name] or -999)) > MOVE_COOLDOWN then
                        if not move_prev[sig_data.name] then
                            move_last[sig_data.name] = now
                            local sw = sig_data.info.signal_windup or sig_data.info.windup
                            local temp_info = {
                                action = sig_data.info.action,
                                windup = sw,
                                hold = sig_data.info.hold,
                                dodge_dir = sig_data.info.dodge_dir,
                            }
                            execute_move(sig_data.name, temp_info, now, pl)
                        end
                    end
                    signal_prev[sig_name] = present
                end
                for nm,t in pairs(dodge_fire) do
                    if t and now >= t then
                        dodge_fire[nm] = nil
                        local info = MOVES[nm]
                        local dir = info and info.dodge_dir or "back"
                        if in_range or (info and info.action == "dodge") then
                            tap_dodge(nm, dir)
                            mode="dodge"
                        end
                    end
                end
                for nm,t in pairs(parry_fire) do
                    if t and now >= t then
                        parry_fire[nm] = nil
                        if in_range then tap_parry("timed:" .. nm); mode="timed" end
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
                    if clash_now and not prev_clash and not action_locked(now) then
                        local has_pending = false
                        for _,_ in pairs(parry_fire) do has_pending=true; break end
                        for _,_ in pairs(dodge_fire) do has_pending=true; break end
                        if not has_pending and block_start == 0 then
                            last_action_time = now
                            tap_parry("clash")
                        end
                    end
                    if BACKUP_ENABLED and signal_now and not prev_signal and not action_locked(now) then
                        local has_named = false
                        for _,_ in pairs(parry_fire) do has_named=true; break end
                        for _,_ in pairs(dodge_fire) do has_named=true; break end
                        if not has_named and (block_start == 0) then
                            backup_time=now+(BACKUP_AFTER_SIGNAL-pl); backup_armed=true
                        end
                    end
                    if backup_armed and now>=backup_time then
                        if not parry_busy and not dodge_busy and not action_locked(now) then
                            last_action_time = now
                            local reaction = classify_and_respond(target, now, pl)
                            if reaction == "dodge" then
                                tap_dodge("fallback", "back")
                            elseif reaction == "block" then
                                block_start = now
                                block_end = now + 0.40
                                show_action(">> BLOCK: unknown")
                            else
                                if has_effect(target, SIGNAL_EFFECT) or enemy_attacking(target) then
                                    tap_parry("backup")
                                end
                            end
                        end
                        backup_armed=false
                    end
                    prev_clash=clash_now; prev_signal=signal_now
                else
                    prev_clash  = clash_state(target)
                    prev_signal = has_effect(target, SIGNAL_EFFECT)
                end
                if not block_active and not parry_busy and not dodge_busy then set_block(false) end
            end
        else
            target=nil; reset_detection()
            if not parry_busy and not dodge_busy then set_block(false) end
        end
        draw_visuals(mr,tr,target,mode)
    end
end
set_block(false); hide_visuals(); script_state.cleanup()
if _G and _G[INSTANCE_KEY]==script_state then _G[INSTANCE_KEY]=nil end
