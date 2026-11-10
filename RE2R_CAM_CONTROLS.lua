-- RE2R CAM CONTROLS
-- Field of view (normal and aiming), camera offset and aim offset (left/right and up/down),
-- quick camera transitions and 3 preset slots, for Resident Evil 2 Remake, inside the
-- REFramework menu.

---------------------------------------------------------------- CONFIG

-- settings and presets (reframework\data); v2.x used RE2R_FOV_CONFIG.json, which is not read
local CONFIG_PATH = "RE2R_CAM_CONTROLS.json"

local cfg = { enabled = true, toggle_key = 0x72 } -- F3
-- cfg.fov_default / cfg.fov_ads: nil = follow the game's own values exactly
-- cfg.game_rest_raw: the game's normal value (read from the camera), remembered between sessions
-- cfg.cam_offset: sideways camera offset in cm (+ right, - left), nil = 0
-- cfg.cam_offset_y: vertical camera offset in cm (+ up, - down), nil = 0
-- cfg.aim_offset / cfg.aim_offset_y: the same for the aiming view, nil = 0
-- cfg.presets: saved setups, "p1".."p3" -> { saved = true, the six values above }

local loaded = json.load_file(CONFIG_PATH)
if type(loaded) == "table" then
    for k, v in pairs(loaded) do cfg[k] = v end
end

local function save() json.dump_file(CONFIG_PATH, cfg) end
local function round1(x) return math.floor(x * 10 + 0.5) / 10 end
local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end

---------------------------------------------------------------- FIELD OF VIEW

local AIM_KEY = 0x02            -- right mouse button
local MOVE_THRESHOLD = 0.4      -- camera must react by this much (bigger than idle sway)
local CONFIRM_WINDOW = 0.35     -- seconds after the press for the camera to react
local ARRIVE_TOL = 0.05         -- or arrive at the known aim value (e.g. aiming from a run)
local ARRIVE_FRAMES = 3
local BLEND_IN_TIME = 0.20      -- seconds for the Normal -> ADS transition
local BLEND_OUT_TIME = 0.20     -- seconds for the ADS -> Normal transition
local KEY_F1, KEY_F12, KEY_ESC = 0x70, 0x7B, 0x1B

-- field of view limits
-- top: past 180 the camera's projection turns inside out and the picture flips upside down
-- bottom: the game refuses anything below 1 degree vertical and shows its default view instead
-- (measured: 1.8 on the slider works, 1.7 snaps to default; 1.78 horizontal = 1.00 vertical at 16:9)
-- the final camera value is always held between these, whatever the game or learned values do
local FOV_MAX_H = 179.0          -- horizontal, as shown in the sliders
local FOV_MIN_V = 1.01           -- vertical, just above the game's 1 degree floor

-- knife stance widens the camera by a fixed ratio of the normal view
-- (measured: 93.00 vs 78.00 at the default setting, 111.60 vs 93.60 at max)
local KNIFE_TO_NORMAL = 93.00 / 78.00
local KNIFE_MARGIN = 0.5        -- knife handling starts this far above the normal/aim values

-- the game's normal and aim field of view (vertical), measured with read-only scans:
-- the in-game FOV setting moves in fixed steps, from min (step 0) to max (step 10)
--   normal = 68.00 + 1.36 per step   (min 68.00, default 74.80, max 81.60)
--   aim    = 55.00 + 1.10 per step   (min 55.00, default 60.50, max 66.00)
-- so the aim value always follows from the normal value, and no aiming is ever needed
local NORMAL_BASE, NORMAL_STEP = 68.00, 1.36
local AIM_BASE, AIM_STEP = 55.00, 1.10
local STEP_MAX = 10
local STEP_TOLERANCE = 0.02     -- a reading must sit this close to a step value to be accepted
local SEED_DEFAULT_RAW = NORMAL_BASE + NORMAL_STEP * 5 -- default setting, until the game is read

local function aim_for(normal)
    return AIM_BASE + (normal - NORMAL_BASE) * (AIM_STEP / NORMAL_STEP)
end

-- the exact normal value for a reading, or nil when it isn't one of the setting's steps
-- (running, knife, aiming, inventory and other special cameras never land on a step)
local function normal_step(v)
    if type(v) ~= "number" or v ~= v then return nil end
    local k = math.floor((v - NORMAL_BASE) / NORMAL_STEP + 0.5)
    if k < 0 or k > STEP_MAX then return nil end
    local exact = NORMAL_BASE + NORMAL_STEP * k
    if math.abs(v - exact) > STEP_TOLERANCE then return nil end
    return exact
end

-- the remembered normal value: kept only if it is one of the setting's steps
if cfg.game_rest_raw ~= nil then
    local exact = normal_step(cfg.game_rest_raw)
    if exact ~= cfg.game_rest_raw then
        cfg.game_rest_raw = exact
        save()
    end
end

-- the game's own states (found with read-only scans): the normal value is read only while the
-- camera shows the plain normal view in normal play
local ORDERER_TYPE = "app.ropeway.survivor.player.PlayerActionOrderer"
local RESTRICT_TYPE = "app.ropeway.survivor.SurvivorRestrictionCollector"
local CAM_SYSTEM_TYPE_FOV = "app.ropeway.camera.CameraSystem"
local STATE_AIMING = 16          -- PlayerActionOrderer.<Petient> while aiming or holding the knife
local STATE_GAMEPLAY = 0         -- SurvivorRestrictionCollector.<MergedTarget> with no menu / inventory / examine
local CAMERA_NORMAL = 0          -- BusyCameraController.<NowKind>: 0 normal, 1 running, 3 aiming or knife
local NORMAL_SETTLE = 10         -- frames the camera must hold still before it is read

local function normal_view_in_gameplay()
    local ok, yes = pcall(function()
        local pm = sdk.get_managed_singleton("app.ropeway.PlayerManager")
        local player = pm and pm:call("get_CurrentPlayer")
        if player == nil then return false end
        local go = player
        pcall(function()
            local g = player:call("get_GameObject")
            if g then go = g end
        end)
        local r = go:call("getComponent(System.Type)", sdk.typeof(RESTRICT_TYPE))
        local o = go:call("getComponent(System.Type)", sdk.typeof(ORDERER_TYPE))
        if r == nil or o == nil then return false end
        if r:get_field("<MergedTarget>k__BackingField") ~= STATE_GAMEPLAY then return false end
        if o:get_field("<Petient>k__BackingField") == STATE_AIMING then return false end
        local cgo = sdk.get_primary_camera():call("get_GameObject")
        local sys = cgo:call("getComponent(System.Type)", sdk.typeof(CAM_SYSTEM_TYPE_FOV))
        local busy = sys:get_field("<BusyCameraController>k__BackingField")
        if busy == nil then return false end
        -- after running, the game keeps the running view (JogHold) even when standing still
        return busy:get_field("<NowKind>k__BackingField") == CAMERA_NORMAL
            and busy:get_field("<JogHold>k__BackingField") == false
    end)
    return ok and yes == true
end

-- state
local aspect = 16 / 9
local game_default_v = cfg.game_rest_raw or SEED_DEFAULT_RAW
-- true once the game's normal value has actually been read (or carried over from a saved one);
-- until then knife handling stays off, since it is placed relative to the normal value and a
-- guessed one would pull a real normal view toward it (a short narrowing at in-game FOV settings
-- above the default, right after Reset or on a first start)
local normal_known = cfg.game_rest_raw ~= nil
local game_ads_v = aim_for(game_default_v)
local last_game_v, last_written = nil, nil
local prev_fov, was_aim_held = nil, false
local aim_active = false
local watching, press_time, arrive_frames = false, 0, 0
local force_request = false     -- set by Reset all overrides: the camera is put back on the next frame
local blend = 0                 -- 0 = Normal, 1 = ADS (linear progress, eased when applied)
local rest_at_press = nil
local stable_value, stable_frames = nil, 0
local dirty, dirty_frames = false, 0
local key_was_down, waiting_for_key = false, false
local confirming_reset = false
-- presets, kept in one table (Lua allows 200 local names per chunk): see PRESETS below
local preset = {
    COUNT = 3,
    FIELDS = { "fov_default", "fov_ads", "cam_offset", "cam_offset_y", "aim_offset", "aim_offset_y" },
    EASE_TIME = 0.20,           -- loading eases into the preset, same time as the other transitions
    SLOT_WIDTH = 48,            -- width of each slot square
    COLOR = 0xFFB0864F,         -- saved slot, light blue (#4F86B0); colors are 0xAABBGGRR
    HOVER = 0xFFC0965F,
    ACTIVE = 0xFFD0A66F,
    menu = nil,                 -- slot whose right-click row (Overwrite / Clear / Cancel) is open
    rmb_prev = false,           -- right mouse button last menu frame (for a fresh click)
    fov_ease = nil,             -- { def = old Normal, ads = old ADS, t = 0..1 } while easing
}

-- sliders are horizontal, the camera works in vertical
local function v_to_h(v)
    return math.deg(2 * math.atan(math.tan(math.rad(v) / 2) * aspect))
end

local function h_to_v(h)
    if h > FOV_MAX_H then h = FOV_MAX_H end -- 180+ breaks the math, so cap before sending to the camera
    return math.deg(2 * math.atan(math.tan(math.rad(h) / 2) / aspect))
end

-- the slider's lowest value: the narrowest view the game will show on this screen, rounded up
-- to the slider's 0.1 steps so the lowest value always shows exactly what it says
-- (about 1.8 at 16:9; wider screens need a little more)
local function fov_min_h()
    return math.ceil(v_to_h(FOV_MIN_V) * 10 - 1e-6) / 10
end

-- slider values (typed or dragged) and saved values always stay within the limits
local function clamp_fov(h)
    if type(h) ~= "number" or h ~= h then return nil end
    local lo = fov_min_h()
    if h < lo then h = lo elseif h > FOV_MAX_H then h = FOV_MAX_H end
    return round1(h)
end

if cfg.fov_default ~= nil then cfg.fov_default = clamp_fov(cfg.fov_default) end
if cfg.fov_ads ~= nil then cfg.fov_ads = clamp_fov(cfg.fov_ads) end

-- where knife handling begins: just above both the normal and aim values
local function knife_start()
    return math.max(game_default_v, game_ads_v) + KNIFE_MARGIN
end

-- real elapsed time for frame-rate independent timing
local app_type = sdk.find_type_definition("via.Application")
local uptime_m = app_type and app_type:get_method("get_UpTimeSecond")
local last_time = nil

local function frame_delta()
    local now = nil
    if uptime_m then
        local ok, v = pcall(function() return uptime_m:call(nil) end)
        if ok and type(v) == "number" then now = v end
    end
    if now == nil then return 1 / 60 end
    local d = last_time and (now - last_time) or 0
    last_time = now
    if d < 0 or d > 0.5 then d = 1 / 60 end
    return d
end

-- controller aim (left trigger); if unavailable, only the mouse is used
local pad_type = sdk.find_type_definition("via.hid.GamePad")
local LT_FLAG = nil
do
    local ok, v = pcall(function()
        local t = sdk.find_type_definition("via.hid.GamePadButton")
        local f = t and t:get_field("LTrigBottom")
        return f and f:get_data(nil)
    end)
    if ok and type(v) == "number" then LT_FLAG = v end
end

local function pad_aim_held()
    if pad_type == nil or LT_FLAG == nil then return false end
    local ok, held = pcall(function()
        local pad = sdk.get_native_singleton("via.hid.GamePad")
        if pad == nil then return false end
        local device = sdk.call_native_func(pad, pad_type, "getMergedDevice", 0)
        if device == nil then return false end
        local buttons = device:call("get_Button")
        if type(buttons) ~= "number" then return false end
        return (buttons & LT_FLAG) ~= 0
    end)
    return ok and held == true
end

-- gameplay detection (keeps menus untouched)
local pm_type = sdk.find_type_definition("app.ropeway.PlayerManager")
local detection_ok = pm_type ~= nil and pm_type:get_method("get_CurrentPlayer") ~= nil

local function is_gameplay()
    if not detection_ok then return true end
    local pm = sdk.get_managed_singleton("app.ropeway.PlayerManager")
    if pm == nil then return false end
    local ok, player = pcall(function() return pm:call("get_CurrentPlayer") end)
    return ok and player ~= nil
end

local function restore(cam)
    if last_written ~= nil and last_game_v ~= nil then
        pcall(function() cam:call("set_FOV", last_game_v) end)
    end
    last_written = nil
end

local function end_aim()
    aim_active = false
    watching, press_time, arrive_frames = false, 0, 0
    rest_at_press = nil
end

-- take a new normal value from the game (one of the setting's exact steps); aim follows from it
local function adopt_normal(v)
    normal_known = true
    game_default_v = v
    game_ads_v = aim_for(v)
    if cfg.game_rest_raw ~= v then
        cfg.game_rest_raw = v
        save()
    end
end

-- AIM ZOOM
-- Zooming into and out of aim runs on its own clock: one smooth curve of SEG_TIME seconds from
-- what is on screen to the slider value, whatever the game's own zoom does underneath.
-- Measured in-game (video, frame by frame): the game's zoom out of aim slows to a crawl near its
-- end (well over half a second); following it, scaled up by far-apart sliders, gave a slow creep
-- and then a kick when it was finally closed. Scaling the game's moving value by a separate blend
-- (the earliest builds) gave two eases on top of each other instead. Neither is used now: during
-- the zoom the game's value is ignored, and the view then holds the end value until the game has
-- come fully to rest, then carries on with the plain ratio scaling (seamless: same value).
-- The curve runs in "zoom" terms (the tangent of the half angle, on a log scale), so the picture
-- grows or shrinks at an even pace even between very wide and very narrow views.
-- Interrupted zooms (letting go mid-zoom, aiming again while zooming out) start a new curve from
-- what is on screen, so nothing jumps. Everything else (knife, running, other cameras, defaults)
-- keeps the ratio scaling as before.
local SEG_TIME = 0.20           -- seconds per zoom (same as the mod's other transitions)
local SEG_MIN_RANGE = 0.05      -- a zoom shorter than this is not animated
local SEG_REST = 0.001          -- the game is at rest when its value moves less than this per frame
local SEG_REST_FRAMES = 6       -- for this many frames in a row
local SEG_TIMEOUT = 2.0         -- seconds; after this the view goes back to the ratio regardless
local seg = nil                 -- { from = on screen at start, b = game end value, kind, t, age, still, last }
local ads_done = false          -- the zoom into this aim has been started

-- the aim value the game is zooming to for this weapon: its aim setting (the controller's
-- NextInfo copy) times the in-game FOV setting's scale (all camera settings scale alike, measured:
-- normal 68 -> 81.60, aim 55 -> 66.00, running 70 -> 84.00 at the highest setting)
local function aim_end_value()
    local v = nil
    pcall(function()
        local cgo = sdk.get_primary_camera():call("get_GameObject")
        local sys = cgo:call("getComponent(System.Type)", sdk.typeof(CAM_SYSTEM_TYPE_FOV))
        local inner = sys:get_field("<BusyCameraController>k__BackingField")
            :get_field("<Param>k__BackingField"):get_field("<NextInfo>k__BackingField")
            :get_field("_Param"):get_field("_Param")
        local f = inner:get_field("_FieldOfView")
        if type(f) == "number" and f == f then v = f * (game_default_v / NORMAL_BASE) end
    end)
    -- only a real aim zoom counts: clearly narrower than the normal view, never below the floor
    if v == nil or v < FOV_MIN_V or v > game_default_v - 0.5 then return nil end
    return v
end

-- even-paced blend between two vertical views (degrees), w = 0..1
local function zoom_lerp(a, b, w)
    local function z(v)
        if v < 0.5 then v = 0.5 elseif v > 179.5 then v = 179.5 end
        return math.log(math.tan(math.rad(v) / 2))
    end
    local za, zb = z(a), z(b)
    return math.deg(2 * math.atan(math.exp(za + (zb - za) * w)))
end

-- what a zoom shows right now
local function seg_value(s, r_end)
    local u = s.t
    local w = u * u * u * (u * (u * 6 - 15) + 10) -- smooth start and stop
    return zoom_lerp(s.from, s.b * r_end, w)
end

re.on_pre_application_entry("BeginRendering", function()
    local dt = frame_delta()

    local cam = sdk.get_primary_camera()
    if cam == nil then return end

    local ok, fov = pcall(function() return cam:call("get_FOV") end)
    if not ok or type(fov) ~= "number" then return end

    local ok_ar, ar = pcall(function() return cam:call("get_AspectRatio") end)
    if ok_ar and type(ar) == "number" and ar > 0.5 and ar < 5 then aspect = ar end

    -- tell the game's own value apart from the one written last frame
    if last_written ~= nil and math.abs(fov - last_written) < 0.001 then
        fov = last_game_v
    else
        last_game_v = fov
    end
    if fov == nil then return end

    -- Reset all overrides: the game's own view right away, all transitions and aim state cleared
    if force_request then
        force_request = false
        restore(cam)
        blend = 0
        seg = nil
        prev_fov, was_aim_held = nil, false
        stable_value, stable_frames = nil, 0
        end_aim()
    end

    if not is_gameplay() then
        restore(cam)
        blend = 0
        seg = nil
        prev_fov, was_aim_held = nil, false
        end_aim()
        return
    end

    -- stability counter (used to read the aim camera once it settles)
    if stable_value ~= nil and math.abs(fov - stable_value) < 0.01 then
        stable_frames = stable_frames + 1
    else
        stable_value, stable_frames = fov, 0
    end

    -- aiming = aim input held (mouse or controller) AND the game's camera reacts to it
    -- (in menus and cutscenes the camera never reacts to the aim input)
    local aim_held = reframework:is_key_down(AIM_KEY) or pad_aim_held()
    local ev_zoom_out = false
    local blend_before = blend -- what was on screen last frame was made with this blend

    if aim_held and not was_aim_held and not aim_active then
        rest_at_press = prev_fov
        watching, press_time, arrive_frames = true, 0, 0
    end
    -- letting go of a confirmed aim
    if not aim_held and was_aim_held and aim_active then ev_zoom_out = true end

    if aim_held then
        if aim_active then
            -- confirmed aim: run our own smooth transition toward ADS
            blend = math.min(1, blend + dt / BLEND_IN_TIME)
        elseif watching and rest_at_press ~= nil then
            press_time = press_time + dt

            local moved = math.abs(fov - rest_at_press) >= MOVE_THRESHOLD
            if math.abs(fov - game_ads_v) < ARRIVE_TOL then
                arrive_frames = arrive_frames + 1
            else
                arrive_frames = 0
            end

            if moved or arrive_frames >= ARRIVE_FRAMES then
                aim_active, watching = true, false
                blend = math.min(1, blend + dt / BLEND_IN_TIME)
            elseif press_time > CONFIRM_WINDOW then
                watching = false -- camera never reacted: not an aim
            end
        end
    else
        if aim_active then
            -- released: run our own smooth transition back to Normal
            blend = math.max(0, blend - dt / BLEND_OUT_TIME)
            if blend <= 0 then end_aim() end
        else
            end_aim()
        end
    end

    was_aim_held = aim_held
    prev_fov = fov

    -- the game's normal value, read whenever the camera holds still on the plain normal view in
    -- normal play (no aiming needed: a change of the in-game FOV setting is picked up as soon as
    -- you are back in play). Only the setting's exact steps are accepted; the aim value follows.
    if not aim_active and not watching and seg == nil and stable_frames >= NORMAL_SETTLE then
        local exact = normal_step(fov)
        if exact and (not normal_known or math.abs(exact - game_default_v) > 0.005)
            and normal_view_in_gameplay() then
            adopt_normal(exact)
        end
    end

    if not cfg.enabled then
        seg = nil
        restore(cam)
        return
    end

    -- both scaled the same way: user value / game's value
    local r_def = 1.0
    if cfg.fov_default then
        r_def = h_to_v(cfg.fov_default) / game_default_v
    end

    local r_ads = 1.0
    if cfg.fov_ads then
        r_ads = h_to_v(cfg.fov_ads) / game_ads_v
    end

    -- a preset was just loaded: ease both values over from the ones before
    if preset.fov_ease then
        preset.fov_ease.t = math.min(1, preset.fov_ease.t + dt / preset.EASE_TIME)
        local u = preset.fov_ease.t
        local w = u * u * u * (u * (u * 6 - 15) + 10)
        local from_def = preset.fov_ease.def and (h_to_v(preset.fov_ease.def) / game_default_v) or 1.0
        local from_ads = preset.fov_ease.ads and (h_to_v(preset.fov_ease.ads) / game_ads_v) or 1.0
        r_def = from_def + (r_def - from_def) * w
        r_ads = from_ads + (r_ads - from_ads) * w
        if preset.fov_ease.t >= 1 then preset.fov_ease = nil end
    end

    local t = blend * blend * (3 - 2 * blend) -- ease in and out
    local r = r_def + (r_ads - r_def) * t

    -- what is on screen right now, before any new zoom starts (a new zoom starts from it)
    local function shown_now()
        if seg then return seg_value(seg, seg.kind == "ads" and r_ads or r_def) end
        local tb = blend_before * blend_before * (3 - 2 * blend_before)
        return fov * (r_def + (r_ads - r_def) * tb)
    end

    -- zoom into aim: starts the moment the game itself switches to the weapon's aim setting,
    -- also when aiming again while still zooming out; once per aim (ads_done), so a game value
    -- that ends up a little off the expected one can never restart it. The knife has no aim
    -- value and keeps the ratio blend. With both FOV sliders on the game's values the view is the
    -- game's own: nothing to animate.
    local custom_fov = math.abs(r_def - 1) > 1e-6 or math.abs(r_ads - 1) > 1e-6
    if not custom_fov then seg = nil end
    if not aim_held then ads_done = false end
    if custom_fov and aim_held and not ads_done and (aim_active or watching)
        and (seg == nil or seg.kind ~= "ads") then
        local b = aim_end_value()
        if b and b < fov - SEG_MIN_RANGE then
            if watching then aim_active, watching = true, false end -- the game confirms the aim
            seg = { from = shown_now(), b = b, kind = "ads", t = 0, age = 0, still = 0, last = fov }
            ads_done = true
        end
    end
    if ev_zoom_out then
        local b = game_default_v
        if custom_fov and fov < b - SEG_MIN_RANGE then
            seg = { from = shown_now(), b = b, kind = "def", t = 0, age = 0, still = 0, last = fov }
        else
            seg = nil
        end
    end

    local target
    if seg then
        local r_end = (seg.kind == "ads") and r_ads or r_def
        seg.t = math.min(1, seg.t + dt / SEG_TIME)
        seg.age = seg.age + dt
        if math.abs(fov - seg.last) < SEG_REST then seg.still = seg.still + 1 else seg.still = 0 end
        seg.last = fov
        target = seg_value(seg, r_end)
        -- done once our curve has finished and the game has come fully to rest
        if seg.t >= 1 and (seg.still >= SEG_REST_FRAMES or seg.age > SEG_TIMEOUT) then
            local ratio_view = fov * r_end
            if math.abs(ratio_view - target) > 0.01 and seg.age <= SEG_TIMEOUT then
                -- the game came to rest somewhere else (e.g. started running): ease over to it
                seg = { from = target, b = fov, kind = seg.kind, t = 0, age = seg.age, still = 0, last = fov }
            else
                if seg.kind == "ads" then
                    blend = 1
                else
                    blend = 0
                    if not aim_held then end_aim() end
                end
                seg = nil
                target = ratio_view
            end
        end
    else
        target = fov * r
    end

    -- knife stance: instead of the game's wide knife view, blend to the Normal view
    -- (only once the game's normal value is known, see normal_known)
    if not aim_active and normal_known then
        local k_start = knife_start()
        local knife_v = game_default_v * KNIFE_TO_NORMAL
        if knife_v > k_start + 1 then
            local k
            if fov <= knife_v then
                k = clamp01((fov - k_start) / (knife_v - k_start))
            else
                -- above the knife value: full hold up to +3%, fading out by +8%
                -- (much wider cameras are something else and are left alone)
                k = clamp01(1 - ((fov - knife_v) / knife_v - 0.03) / 0.05)
            end
            if k > 0 then
                local default_view = game_default_v * r_def
                target = target + (default_view - target) * k
            end
        end
    end

    -- hard limits on what reaches the camera, whatever the inputs: never wider than the slider's
    -- maximum (the picture can never flip), never narrower than the game's floor (it would snap
    -- to the default view); anything that isn't a number also ends up at the floor
    local max_v = h_to_v(FOV_MAX_H)
    if target > max_v then target = max_v end
    if not (target >= FOV_MIN_V) then target = FOV_MIN_V end

    if math.abs(target - fov) < 0.0005 then restore(cam) return end

    if pcall(function() cam:call("set_FOV", target) end) then
        last_written = target
    end
end)

---------------------------------------------------------------- CAMERA OFFSET

-- Two offsets, each with its own sliders: the camera offset (normal view) and the aim offset
-- (aiming view). Both are written into the game's own camera settings, so the game does everything
-- else itself: wall collision (with its own "avoid" offset), interaction prompts, smooth
-- transitions between views.
-- Where the settings live (found with read-only scans):
--   1. the character's settings, used in most rooms:
--      player -> app.ropeway.camera.PlayerCameraPositionSetting -> UserData
--        -> _Normal / _Jog -> _Param -> _Param -> _Offset        (Claire: 0.48 right, 1.42 up)
--        -> _Hold -> _Params[n] (one per weapon) -> _UserData -> _Param -> _Param -> _Offset
--        -> _Hold -> _Default (weapons without their own entry) -> _Param -> _Param -> _Offset
--           every entry follows the aim offset, guns and knife alike
--           (Claire's handgun: 0.48 right, 0.41 up from the spine; knife: 0.46 right, 1.25 up)
--   2. area overrides, which some rooms switch on (e.g. the Main Hall):
--      camera -> app.ropeway.camera.CameraSystem -> BusyCameraController -> OverwriteParam
--        -> _Normal / _Jog -> _Offset                            (Main Hall: 0.40 / 0.00 right, 1.52 up)
--      (overrides have no aim views: aiming always uses the character's settings)
-- Each setting's original value is remembered per object for the whole session, so entering a
-- room twice never stacks the offset, and settings shared by several weapons are offset once.
-- Settings are put back when an offset or the mod is turned off, when an area override stops
-- being used, and when scripts are reset.
-- The game copies the setting in use into its controller when the camera state changes
-- (BusyCameraController -> Param -> PrevInfo / NextInfo, always a copy, measured); that copy is
-- updated too, so changes apply at once, also mid-aim. Only a copy that exactly matches one of
-- our settings (same offset and field of view) is ever touched. Special cameras (typewriter,
-- doors, cutscenes, grabs) use other settings and are never touched. Nothing is written to the
-- camera itself.
-- The game smooths its camera position (BusyCameraController -> DampingCameraPos, 0.2 s), which
-- made every offset change trail behind. When an offset changes while the game is using one of
-- its settings, that smoothing's current position is moved by the same amount, so the camera
-- follows our own 0.20 s ease exactly, like the Normal <-> ADS FOV blend.

local CAM_SETTING_TYPE = "app.ropeway.camera.PlayerCameraPositionSetting"
local CAM_SYSTEM_TYPE = "app.ropeway.camera.CameraSystem"
local CAM_STATES = { "_Normal", "_Jog" } -- standing/walking and running
local CAM_MAX_HOLD = 64                  -- safety cap on the weapon list (Claire: 19)
local CAM_CHECK_INTERVAL = 0.25          -- seconds between checks for a new character / area override
local CAM_TRANSITION_TIME = 0.20         -- seconds to ease the offsets on toggle and preset load
                                         -- (same time and curve as the Normal <-> ADS FOV blend)
                                         -- (slider drags always apply instantly)

-- the two offsets: their saved values (cm) and their own transition
--   wanted: where the offset is heading, from: where the transition started,
--   out: what is written right now, t: transition progress (1 = finished)
local cam_groups = {
    body = { x_key = "cam_offset", y_key = "cam_offset_y" },
    aim = { x_key = "aim_offset", y_key = "aim_offset_y" },
}
local CAM_GROUP_ORDER = { "body", "aim" }
for _, g in pairs(cam_groups) do
    g.wanted, g.from, g.out, g.t = { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 }, 1
end

-- every setting we have seen: key -> { param, base = {x,y,z}, fov, applied = {x,y}, group }
local cam_known = {}
local cam_active = {}                    -- keys of the settings the game can use right now
local cam_prev_enabled = cfg.enabled     -- to notice the toggle (hotkey / checkbox)
local cam_reset_request = false          -- set by a preset load: ease to the new offsets
local cam_next_check = 0
local cam_last_up = nil

-- own clock, so the FOV timing (frame_delta) is never disturbed
local function cam_dt()
    local now = nil
    if uptime_m then
        local ok, v = pcall(function() return uptime_m:call(nil) end)
        if ok and type(v) == "number" then now = v end
    end
    if now == nil then return 1 / 60 end
    local d = cam_last_up and (now - cam_last_up) or 0
    cam_last_up = now
    if d < 0 or d > 0.5 then d = 1 / 60 end
    return d
end

local function cam_addr(obj)
    local a = nil
    if obj then pcall(function() a = obj:get_address() end) end
    return a
end

local function cam_busy_controller()
    local busy = nil
    pcall(function()
        local go = sdk.get_primary_camera():call("get_GameObject")
        local sys = go:call("getComponent(System.Type)", sdk.typeof(CAM_SYSTEM_TYPE))
        busy = sys:get_field("<BusyCameraController>k__BackingField")
    end)
    return busy
end

-- remember a setting the first time we see it (its untouched value becomes the base);
-- each setting is listed once, even when several weapons share it
local function cam_track(key, param, list, seen, group)
    if param == nil or seen[key] then return end
    if cam_known[key] == nil then
        local v, fov = nil, nil
        pcall(function()
            v = param:get_field("_Offset")
            fov = param:get_field("_FieldOfView")
        end)
        if v == nil or type(v.x) ~= "number" or type(v.y) ~= "number" or type(v.z) ~= "number" then
            return
        end
        cam_known[key] = { param = param, base = { x = v.x, y = v.y, z = v.z }, fov = fov,
            applied = { x = 0, y = 0 }, group = group }
    end
    seen[key] = true
    list[#list + 1] = key
end

-- the entries of a game list (engine list first, then Count / Item)
local function cam_list_items(l)
    local out = {}
    if l == nil then return out end
    pcall(function()
        local size = l:get_field("mSize")
        local el = l:get_field("mItems"):get_elements()
        for i, e in ipairs(el) do
            if i > CAM_MAX_HOLD or (type(size) == "number" and i > size) then break end
            out[#out + 1] = e
        end
    end)
    if #out > 0 then return out end
    pcall(function()
        local n = l:call("get_Count")
        for i = 0, math.min(n, CAM_MAX_HOLD) - 1 do
            local e = l:call("get_Item", i)
            if e ~= nil then out[#out + 1] = e end
        end
    end)
    return out
end

-- the aim settings: every weapon's entry plus the default one
local function cam_track_hold(ud, list, seen)
    local hold = ud:get_field("_Hold")
    if hold == nil then return end
    local params = {}
    pcall(function()
        params[#params + 1] = hold:get_field("_Default"):get_field("_Param"):get_field("_Param")
    end)
    for _, hp in ipairs(cam_list_items(hold:get_field("_Params"))) do
        pcall(function()
            params[#params + 1] = hp:get_field("_UserData"):get_field("_Param"):get_field("_Param")
        end)
    end
    for _, p in ipairs(params) do
        local pa = cam_addr(p)
        if pa then
            cam_track("h" .. pa, p, list, seen, "aim")
        end
    end
end

local function cam_find_active()
    local list, seen = {}, {}
    -- 1. character settings
    if detection_ok then
        pcall(function()
            local pm = sdk.get_managed_singleton("app.ropeway.PlayerManager")
            local player = pm and pm:call("get_CurrentPlayer")
            if player == nil then return end
            local go = player
            pcall(function()
                local g = player:call("get_GameObject")
                if g then go = g end
            end)
            local setting = go:call("getComponent(System.Type)", sdk.typeof(CAM_SETTING_TYPE))
            local ud = setting and setting:get_field("UserData")
            local ua = cam_addr(ud)
            if ud == nil or ua == nil then return end
            for _, state in ipairs(CAM_STATES) do
                pcall(function()
                    local p = ud:get_field(state):get_field("_Param"):get_field("_Param")
                    cam_track("ud" .. ua .. state, p, list, seen, "body")
                end)
            end
            pcall(cam_track_hold, ud, list, seen)
        end)
    end
    -- 2. area override (only present in some rooms)
    pcall(function()
        local busy = cam_busy_controller()
        local ow = busy and busy:get_field("<OverwriteParam>k__BackingField")
        local oa = cam_addr(ow)
        if ow == nil or oa == nil then return end
        for _, state in ipairs(CAM_STATES) do
            pcall(function() cam_track("ow" .. oa .. state, ow:get_field(state), list, seen, "body") end)
        end
    end)
    return list
end

local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.001 end

-- does a live copy hold exactly this setting's current value
local function cam_copy_matches(e, inner)
    local v = inner:get_field("_Offset")
    local fov = inner:get_field("_FieldOfView")
    local b, old = e.base, e.applied
    return near(v.x, b.x + old.x) and near(v.y, b.y + old.y) and near(v.z, b.z) and near(fov, e.fov)
end

-- which offset the camera is heading to right now ("body", "aim"), or nil for any other camera
-- (typewriter, doors, cutscenes): the setting whose value the controller's NextInfo copy holds
local function cam_live_group()
    local group = nil
    pcall(function()
        local inner = cam_busy_controller():get_field("<Param>k__BackingField")
            :get_field("<NextInfo>k__BackingField"):get_field("_Param"):get_field("_Param")
        for _, e in pairs(cam_known) do
            if cam_copy_matches(e, inner) then group = e.group break end
        end
    end)
    return group
end

-- move the controller's live copies from one setting's old value to its new value (exact match only)
-- NextInfo is the view the camera is heading to; PrevInfo is the view it is leaving, still blended
-- in while the game's transition runs (e.g. the last moments of letting go of aim). The leaving view
-- only follows when it belongs to the same offset as the view being entered (normal <-> running);
-- otherwise it stays as it was, so changing one offset never shows in the other one's view
-- (toggling right after letting go of aim no longer moves the camera through the fading aim view).
local function cam_patch_live(e, new_x, new_y, live_group)
    local busy = cam_busy_controller()
    if busy == nil then return false end
    local b = e.base
    local active_matched = false
    for _, info_name in ipairs({ "<PrevInfo>k__BackingField", "<NextInfo>k__BackingField" }) do
        local is_next = info_name == "<NextInfo>k__BackingField"
        if is_next or e.group == live_group then pcall(function()
            local param = busy:get_field("<Param>k__BackingField")
            local info = param:get_field(info_name)
            local cont = info:get_field("_Param")
            local inner = cont:get_field("_Param")
            if cam_copy_matches(e, inner) then
                inner:set_field("_Offset", Vector3f.new(b.x + new_x, b.y + new_y, b.z))
                -- written back up the chain in case these are copies (value types)
                cont:set_field("_Param", inner)
                info:set_field("_Param", cont)
                param:set_field(info_name, info)
                if is_next then active_matched = true end
            end
        end) end
    end
    return active_matched
end

-- write one setting to base + (x, y), only if it differs from what it holds now
-- returns true when the game is using this setting right now (its live copy matched)
local function cam_set(e, x, y, live_group)
    if e.applied.x == x and e.applied.y == y then return false end
    local b = e.base
    pcall(function() e.param:set_field("_Offset", Vector3f.new(b.x + x, b.y + y, b.z)) end)
    local in_use = cam_patch_live(e, x, y, live_group)
    e.applied = { x = x, y = y }
    return in_use
end

-- move the game's smoothed camera position by the offset change (dx right, dy up, metres),
-- so the camera lands on the new offset at once instead of trailing behind
local function cam_shift_damping(dx, dy)
    if dx == 0 and dy == 0 then return end
    pcall(function()
        local busy = cam_busy_controller()
        local damp = busy:get_field("<DampingCameraPos>k__BackingField")
        local cur = damp:get_field("<Current>k__BackingField")
        if cur == nil or type(cur.x) ~= "number" then return end
        -- camera's right direction, kept level (the offset is level right/left and straight up)
        local tf = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
        local q = tf:call("get_Rotation")
        local rx = 1 - 2 * (q.y * q.y + q.z * q.z)
        local rz = 2 * (q.x * q.z - q.w * q.y)
        local len = math.sqrt(rx * rx + rz * rz)
        if len < 0.001 then return end
        rx, rz = rx / len, rz / len
        damp:set_field("<Current>k__BackingField",
            Vector3f.new(cur.x + rx * dx, cur.y + dy, cur.z + rz * dx))
    end)
end

-- write a list of settings to their targets; the camera's smoothing follows the one in use
-- (target(e) gives x, y for a setting)
local function cam_write(entries, target)
    local shifted, sx, sy = false, 0, 0
    local live_group = nil
    for _, e in ipairs(entries) do
        local x, y = target(e)
        if e.applied.x ~= x or e.applied.y ~= y then
            live_group = cam_live_group() -- read once, before anything is written
            break
        end
    end
    for _, e in ipairs(entries) do
        local px, py = e.applied.x, e.applied.y
        local x, y = target(e)
        if cam_set(e, x, y, live_group) and not shifted then
            shifted, sx, sy = true, x - px, y - py
        end
    end
    if shifted then cam_shift_damping(sx, sy) end
end

local function cam_active_entries()
    local list = {}
    for _, key in ipairs(cam_active) do
        local e = cam_known[key]
        if e and cam_groups[e.group] then list[#list + 1] = e end
    end
    return list
end

local function cam_group_target(e)
    local g = cam_groups[e.group]
    return g.out.x, g.out.y
end

local function cam_zero() return 0, 0 end

local function cam_restore_all()
    local all = {}
    for _, e in pairs(cam_known) do all[#all + 1] = e end
    cam_write(all, cam_zero)
end

-- saved offsets: whole cm within the sliders' range, anything else is dropped
for _, g in pairs(cam_groups) do
    for _, k in ipairs({ g.x_key, g.y_key }) do
        local v = cfg[k]
        if v ~= nil then
            if type(v) ~= "number" or v ~= v then
                cfg[k] = nil
            else
                v = math.floor(math.max(-100, math.min(100, v)) + 0.5)
                cfg[k] = (v ~= 0) and v or nil
            end
        end
    end
end

re.on_frame(function()
    local dt = cam_dt()
    local now = os.clock()

    -- a new target: toggle and preset loads ease to it from wherever the offset is right now,
    -- slider drags apply instantly
    local ease = (cfg.enabled ~= cam_prev_enabled) or cam_reset_request
    cam_prev_enabled = cfg.enabled
    cam_reset_request = false

    local changed, moving = false, false
    for _, name in ipairs(CAM_GROUP_ORDER) do
        local g = cam_groups[name]
        local tx, ty = 0, 0
        if cfg.enabled then
            tx = (cfg[g.x_key] or 0) / 100 -- cm -> m, + right
            ty = (cfg[g.y_key] or 0) / 100 -- cm -> m, + up
        end
        if tx ~= g.wanted.x or ty ~= g.wanted.y then
            g.wanted = { x = tx, y = ty }
            if ease then
                g.from = { x = g.out.x, y = g.out.y }
                g.t = 0
            else
                g.out = { x = tx, y = ty }
                g.t = 1
            end
            changed = true
        end
        if g.t < 1 then
            g.t = math.min(1, g.t + dt / CAM_TRANSITION_TIME)
            local s = g.t * g.t * (3 - 2 * g.t) -- same ease as the FOV
            g.out = {
                x = g.from.x + (g.wanted.x - g.from.x) * s,
                y = g.from.y + (g.wanted.y - g.from.y) * s,
            }
            moving = true
        end
    end

    -- which settings can the game use right now (character + area override), checked regularly
    if now >= cam_next_check then
        cam_next_check = now + CAM_CHECK_INTERVAL
        cam_active = cam_find_active()
        local is_active = {}
        for _, key in ipairs(cam_active) do is_active[key] = true end
        -- settings no longer in use (left the area, changed character): put them back
        local gone = {}
        for key, e in pairs(cam_known) do
            if not is_active[key] then gone[#gone + 1] = e end
        end
        cam_write(gone, cam_zero)
    elseif not (changed or moving) then
        return
    end

    -- settings in use: apply the current (eased) offsets
    cam_write(cam_active_entries(), cam_group_target)
end)

re.on_script_reset(function() cam_restore_all() end)

---------------------------------------------------------------- TRANSITION TIMING

-- How fast the camera moves between views (normal, running, aiming, knife), found with read-only
-- scans. Every move uses one timing pair from the camera settings: the leaving setting's _Output
-- when its _UseOutput is on (aim settings), otherwise the entering setting's _Input. A timing is
-- "DampingRate of the way in DampingTime seconds". Vanilla (measured in game):
--   aim in 80% in 0.2 s, letting go of aim 90% in 0.8 s (still creeping after 1.5 s),
--   knife away and back from running 70% in 3.0 s, start running 90% in 2.0 s
-- The camera's position follows those slow timings while the FOV now finishes in 0.20 s, which
-- showed as a small zoom after the zoom (the camera still sliding ~40 cm after aiming).
-- While the mod is on, every one of those timings is set to TRANS_RATE in TRANS_TIME, so position
-- and FOV finish together, everywhere. Put back exactly when the mod is turned off and on reset.
--
-- How they are written (measured, RE2R_CAM_TIMING_LAYOUT_SCAN): the timings are stored inline in
-- the setting (app.ropeway.camera.PlayerCameraTransitionParam) as app.ropeway.DampingParam
-- structs: _Input at +24 (rate +24, time +28), _Output at +32 (rate +32, time +36), all
-- System.Single; read through the game's own field lookup and straight from memory, all equal.
-- So each number is written as one 4-byte float at its own position, nothing else is touched.
-- (Writing the whole struct back through set_field is what broke the camera in an earlier test.)
-- The positions are taken from the game's own type information at run time, and every setting is
-- checked before its first write: each number read from memory must equal the game's own value,
-- or that setting is left alone.

-- (kept in its own block: nothing outside uses these names, and Lua allows 200 local names per
-- chunk)
do
    local TRANS_RATE = 0.90                  -- share of the way ...
    local TRANS_TIME = 0.15                  -- ... in this many seconds (the FOV curve is 90% there at 0.15 s too)
    local TRANS_CHECK_INTERVAL = 0.25        -- seconds between checks for new settings (new character)
    local TRANS_PARTS = {
        { field = "_Input", inner = "DampingRate", value = TRANS_RATE },
        { field = "_Input", inner = "DampingTime", value = TRANS_TIME },
        { field = "_Output", inner = "DampingRate", value = TRANS_RATE },
        { field = "_Output", inner = "DampingTime", value = TRANS_TIME },
    }

    local trans_known = {}                   -- address -> { obj, offs = {..}, orig = {..}, applied }
    local trans_layouts = {}                 -- type name -> offsets (false = not usable)
    local trans_next_check = 0
    local trans_prev_enabled = nil

    local function trans_find_field(td, name)
        local depth = 0
        while td and depth < 8 do
            depth = depth + 1
            local f = nil
            pcall(function() f = td:get_field(name) end)
            if f then return f end
            local parent = nil
            pcall(function() parent = td:get_parent_type() end)
            td = parent
        end
        return nil
    end

    -- memory positions of the four numbers for this setting's type, from the game's type information
    local function trans_layout(tp)
        local td, tname = nil, nil
        pcall(function()
            td = tp:get_type_definition()
            tname = td:get_full_name()
        end)
        if td == nil or tname == nil then return nil end
        if trans_layouts[tname] ~= nil then return trans_layouts[tname] or nil end
        local offs = {}
        local ok = pcall(function()
            for i, part in ipairs(TRANS_PARTS) do
                local fd = trans_find_field(td, part.field)
                local ftype = fd:get_type()
                if not ftype:is_value_type() then error("not inline") end
                local ifd = trans_find_field(ftype, part.inner)
                local itype = ifd:get_type():get_full_name()
                if itype ~= "System.Single" then error("not a float") end
                offs[i] = fd:get_offset_from_base() + ifd:get_offset_from_fieldptr()
                if type(offs[i]) ~= "number" then error("no offset") end
            end
        end)
        trans_layouts[tname] = ok and offs or false
        return ok and offs or nil
    end

    local function trans_by_field(tp, part)
        local v = nil
        pcall(function() v = tp:get_field(part.field):get_field(part.inner) end)
        return v
    end

    local function trans_read(tp, off)
        local v = nil
        pcall(function() v = tp:read_float(off) end)
        return v
    end

    -- remember a setting the first time it is seen: only if every number in memory matches the
    -- game's own value (proves the positions for this very object)
    local function trans_track(tp)
        local a = cam_addr(tp)
        if a == nil then return end
        if trans_known[a] then return trans_known[a] end
        local offs = trans_layout(tp)
        if offs == nil then return nil end
        local orig = {}
        for i, part in ipairs(TRANS_PARTS) do
            local f = trans_by_field(tp, part)
            local m = trans_read(tp, offs[i])
            if type(f) ~= "number" or type(m) ~= "number" or f ~= f or math.abs(f - m) > 1e-6 then return nil end
            orig[i] = m
        end
        local e = { obj = tp, offs = offs, orig = orig, applied = false }
        trans_known[a] = e
        return e
    end

    -- write the four numbers (one float each), then read them back
    local function trans_write(e, values)
        local ok = true
        for i = 1, #TRANS_PARTS do
            pcall(function() e.obj:write_float(e.offs[i], values[i]) end)
            local back = trans_read(e.obj, e.offs[i])
            if type(back) ~= "number" or math.abs(back - values[i]) > 1e-6 then ok = false end
        end
        return ok
    end

    local function trans_apply(e)
        if e.applied then return end
        local values = {}
        for i, part in ipairs(TRANS_PARTS) do values[i] = part.value end
        if trans_write(e, values) then
            e.applied = true
        else
            trans_write(e, e.orig) -- anything unexpected: back to the game's own values
        end
    end

    local function trans_restore(e)
        if not e.applied then return end
        trans_write(e, e.orig)
        e.applied = false
    end

    local function trans_restore_all()
        for _, e in pairs(trans_known) do trans_restore(e) end
    end

    -- the settings with timings: normal, running, the aim default and every weapon's aim entry
    local function trans_find_settings()
        local list = {}
        if not detection_ok then return list end
        pcall(function()
            local pm = sdk.get_managed_singleton("app.ropeway.PlayerManager")
            local player = pm and pm:call("get_CurrentPlayer")
            if player == nil then return end
            local go = player
            pcall(function()
                local g = player:call("get_GameObject")
                if g then go = g end
            end)
            local setting = go:call("getComponent(System.Type)", sdk.typeof(CAM_SETTING_TYPE))
            local ud = setting and setting:get_field("UserData")
            if ud == nil then return end
            for _, state in ipairs(CAM_STATES) do
                pcall(function() list[#list + 1] = ud:get_field(state):get_field("_Param") end)
            end
            local hold = ud:get_field("_Hold")
            if hold == nil then return end
            pcall(function() list[#list + 1] = hold:get_field("_Default"):get_field("_Param") end)
            for _, hp in ipairs(cam_list_items(hold:get_field("_Params"))) do
                pcall(function() list[#list + 1] = hp:get_field("_UserData"):get_field("_Param") end)
            end
        end)
        return list
    end

    re.on_frame(function()
        local now = os.clock()
        local toggled = cfg.enabled ~= trans_prev_enabled
        if not toggled and now < trans_next_check then return end
        trans_prev_enabled = cfg.enabled
        trans_next_check = now + TRANS_CHECK_INTERVAL

        if not cfg.enabled then
            trans_restore_all()
            return
        end
        for _, tp in ipairs(trans_find_settings()) do
            local e = trans_track(tp)
            if e then trans_apply(e) end
        end
    end)

    re.on_script_reset(function() trans_restore_all() end)
end

---------------------------------------------------------------- HOTKEY

local function key_name(k)
    if k >= KEY_F1 and k <= KEY_F12 then return "F" .. (k - 0x6F) end
    return string.format("Key 0x%02X", k)
end

re.on_frame(function()
    -- Esc cancels a pending reset, like it cancels the hotkey change
    if confirming_reset and reframework:is_key_down(KEY_ESC) then confirming_reset = false end
    if preset.menu and reframework:is_key_down(KEY_ESC) then preset.menu = nil end

    if waiting_for_key then
        if reframework:is_key_down(KEY_ESC) then
            waiting_for_key = false -- Esc cancels, never assigned
            return
        end
        for k = KEY_F1, KEY_F12 do
            if reframework:is_key_down(k) then
                cfg.toggle_key = k
                waiting_for_key = false
                key_was_down = true
                save()
                break
            end
        end
        return
    end

    local down = reframework:is_key_down(cfg.toggle_key)
    if down and not key_was_down then
        cfg.enabled = not cfg.enabled
        save()
    end
    key_was_down = down

    if dirty then
        dirty_frames = dirty_frames + 1
        if dirty_frames > 60 then save(); dirty, dirty_frames = false, 0 end
    end
end)

---------------------------------------------------------------- TOGGLE NOTICE

-- "RE2R CAM CONTROLS: ON / OFF" at the top center of the screen whenever the mod is turned on or
-- off (hotkey or checkbox). Shown for NOTICE_TIME seconds, fading out over the last NOTICE_FADE.
local NOTICE_TIME = 2.0
local NOTICE_FADE = 0.5
local NOTICE_SIZE = 30                   -- font size in pixels
local NOTICE_TOP = 60                    -- distance from the top of the screen
local NOTICE_WHITE = 0xFFFFFFFF          -- colors are 0xAABBGGRR
local NOTICE_GREEN = 0xFF33E033
local NOTICE_RED = 0xFF3333F0
local NOTICE_SHADOW = 0xC0000000
-- window flags: no title bar, resize, move, scrollbar, background, saved settings, mouse,
-- focus or navigation; sizes itself to the text
local NOTICE_FLAGS = 1 + 2 + 4 + 8 + 64 + 128 + 256 + 512 + 4096 + 262144 + 524288

local notice_font = nil
pcall(function() notice_font = imgui.load_font(nil, NOTICE_SIZE) end)

-- real time (game uptime); os.clock counts CPU time, which runs faster in a multi-threaded game
local function notice_now()
    if uptime_m then
        local ok, v = pcall(function() return uptime_m:call(nil) end)
        if ok and type(v) == "number" then return v end
    end
    return os.clock()
end

local notice_prev = cfg.enabled
local notice_on, notice_until = false, 0

-- bold look: the text drawn twice, one pixel apart, over a soft shadow
local function notice_text(text, color)
    local p = imgui.get_cursor_pos()
    imgui.set_cursor_pos(Vector2f.new(p.x + 2, p.y + 2))
    imgui.text_colored(text, NOTICE_SHADOW)
    imgui.set_cursor_pos(Vector2f.new(p.x + 1, p.y))
    imgui.text_colored(text, color)
    imgui.set_cursor_pos(p)
    imgui.text_colored(text, color)
end

re.on_frame(function()
    local now = notice_now()
    if cfg.enabled ~= notice_prev then
        notice_prev = cfg.enabled
        notice_on, notice_until = cfg.enabled, now + NOTICE_TIME
    end
    local left = notice_until - now
    if left <= 0 then return end

    -- every push is paired with its pop even if a step fails, so REFramework's own menu
    -- can never be left in a broken state
    local alpha = math.min(1, left / NOTICE_FADE)
    local pushed_var, pushed_font = false, false
    pcall(function()
        local size = imgui.get_display_size()
        imgui.set_next_window_pos(Vector2f.new(size.x / 2, NOTICE_TOP), 1, Vector2f.new(0.5, 0))
    end)
    pushed_var = pcall(imgui.push_style_var, 0, alpha) -- whole notice fades together
    if notice_font then pushed_font = pcall(imgui.push_font, notice_font) end

    local ok, open = pcall(imgui.begin_window, "##re2r_cam_notice", true, NOTICE_FLAGS)
    if ok and open then
        pcall(function()
            notice_text("RE2R CAM CONTROLS: ", NOTICE_WHITE)
            imgui.same_line(0, 0)
            if notice_on then
                notice_text("ON", NOTICE_GREEN)
            else
                notice_text("OFF", NOTICE_RED)
            end
        end)
        pcall(imgui.end_window)
    end

    if pushed_font then pcall(imgui.pop_font) end
    if pushed_var then pcall(imgui.pop_style_var, 1) end
end)

---------------------------------------------------------------- UI

-- ImGui style indices (standard ImGui order)
local VAR_FRAME_PADDING   = 11
local VAR_FRAME_ROUNDING  = 12
local VAR_FRAME_BORDER    = 13
local VAR_ITEM_SPACING    = 14
local VAR_GRAB_ROUNDING   = 21
local COL_BUTTON          = 21
local COL_BUTTON_HOVERED  = 22
local COL_BUTTON_ACTIVE   = 23

-- menu look (colors are 0xAABBGGRR)
local FRAME_PADDING = { 20, 8 }  -- inside bars and buttons (x, y)
local ITEM_SPACING = { 10, 8 }   -- between items (x, y)
local ROUNDING = 12.0
local BORDER = 0.0
local BAR_WIDTH = 200
local LABEL_GAP = 20
local GAP_AFTER_HOTKEY = 1       -- imgui.spacing() lines
local GAP_BETWEEN_SECTIONS = 1
local GAP_BEFORE_RESETS = 2
local WAITING_COLOR = 0xFF0090E0 -- amber, for two-step actions
local HEADER_COLOR = 0xFFEAC5C9  -- section headers (#C9C5EA)
local DANGER_COLOR = 0xFF4A4A8A  -- Reset all overrides button (#8A4A4A)
local DANGER_HOVER = 0xFF5A5A9A
local DANGER_ACTIVE = 0xFF6A6AAA
local HOTKEY_COLOR = 0xFF5C8A4E  -- Toggle Hotkey button, soft green (#4E8A5C)
local HOTKEY_HOVER = 0xFF6C9A5E
local HOTKEY_ACTIVE = 0xFF7CAA6E

local function safe(f, ...)
    if f then pcall(f, ...) end
end

local function gap(n)
    for _ = 1, n do safe(imgui.spacing) end
end

local function cursor_pos()
    if imgui.get_cursor_pos then
        local ok, p = pcall(imgui.get_cursor_pos)
        if ok and p and p.x and p.y then return p end
    end
    return nil
end

local function set_pos(x, y)
    if imgui.set_cursor_pos and Vector2f then pcall(imgui.set_cursor_pos, Vector2f.new(x, y)) end
end

local function text_w(s)
    if imgui.calc_text_size then
        local ok, sz = pcall(imgui.calc_text_size, s)
        if ok and sz and sz.x then return sz.x end
    end
    return #s * 7
end

local function push_amber()
    local n = 0
    for _, idx in ipairs({ COL_BUTTON, COL_BUTTON_HOVERED, COL_BUTTON_ACTIVE }) do
        if imgui.push_style_color and pcall(imgui.push_style_color, idx, WAITING_COLOR) then
            n = n + 1
        end
    end
    return n
end

local function push_button_colors(normal, hover, active)
    local n = 0
    for _, c in ipairs({ { COL_BUTTON, normal }, { COL_BUTTON_HOVERED, hover }, { COL_BUTTON_ACTIVE, active } }) do
        if imgui.push_style_color and pcall(imgui.push_style_color, c[1], c[2]) then
            n = n + 1
        end
    end
    return n
end

local function push_danger() return push_button_colors(DANGER_COLOR, DANGER_HOVER, DANGER_ACTIVE) end
local function push_green() return push_button_colors(HOTKEY_COLOR, HOTKEY_HOVER, HOTKEY_ACTIVE) end

local function header(text, first)
    if not first then gap(GAP_BETWEEN_SECTIONS) end
    imgui.text_colored(text, HEADER_COLOR)
end

local function pop_colors(n)
    for _ = 1, n do safe(imgui.pop_style_color) end
end

local function push_style()
    local count = 0
    local function var(idx, val)
        if imgui.push_style_var and pcall(imgui.push_style_var, idx, val) then
            count = count + 1
        end
    end
    var(VAR_FRAME_ROUNDING, ROUNDING)
    var(VAR_GRAB_ROUNDING, ROUNDING)
    var(VAR_FRAME_BORDER, BORDER)
    if Vector2f then
        var(VAR_FRAME_PADDING, Vector2f.new(FRAME_PADDING[1], FRAME_PADDING[2]))
        var(VAR_ITEM_SPACING, Vector2f.new(ITEM_SPACING[1], ITEM_SPACING[2]))
    end
    return count
end

local function pop_style(count)
    for _ = 1, count do safe(imgui.pop_style_var) end
end

-- "Label: [bar]" row, left aligned, all bars lined up in one shared column
local ROW_LABELS = { "Normal:", "ADS:", "Offset X:", "ADS-Offset X:", "Offset Y:", "ADS-Offset Y:", "Presets:" }

local function slider_row(label, id, value, speed, min, max, fmt)
    local p = cursor_pos()
    local label_w = 0
    for _, l in ipairs(ROW_LABELS) do label_w = math.max(label_w, text_w(l)) end

    -- label moved down by the bar's inner padding, so its text sits on the same line as the
    -- bar's value; the bar then starts back at the row's top, in the shared column
    if p then set_pos(p.x, p.y + FRAME_PADDING[2]) end
    imgui.text(label)
    imgui.same_line()
    if p then set_pos(p.x + label_w + LABEL_GAP, p.y) end

    safe(imgui.set_next_item_width, BAR_WIDTH)
    local changed, nv = imgui.drag_float("##" .. id, value, speed, min, max, fmt)
    return changed, nv
end

local function fov_row(label, id, value)
    return slider_row(label, id, value, 0.1, fov_min_h(), FOV_MAX_H, "%.1f")
end

local function offset_row(label, id, value)
    return slider_row(label, id, value, 0.5, -100.0, 100.0, "%.0f")
end

-- one offset slider bound to its saved value (whole cm, -100..100, 0 saved as nothing)
local function offset_setting(label, key)
    local changed, o = offset_row(label, key, cfg[key] or 0)
    if changed and type(o) == "number" and o == o then
        o = math.floor(math.max(-100, math.min(100, o)) + 0.5)
        if o == 0 then cfg[key] = nil else cfg[key] = o end
        dirty = true
    end
end

-- PRESETS: three slots, each holding the whole setup (Normal and ADS FOV, the four offsets),
-- kept in the config file under "presets". Shown as a row of slot squares [1] [2] [3] right below
-- the offsets: grey when empty, light blue when saved.
--   Left-click an empty slot: saves into it.
--   Left-click a saved slot: loads it, easing over 0.20 s like the toggle.
--   Right-click a saved slot: the row turns into "Slot #:" Overwrite / Clear (amber: something is
--     lost; picking one is the confirmation) and Cancel; Esc cancels.
-- Hovering a slot shows what its clicks do.

function preset.get(i)
    local p = type(cfg.presets) == "table" and cfg.presets["p" .. i] or nil
    if type(p) == "table" and p.saved == true then return p end
    return nil
end

-- a stored value made safe: FOV within the slider limits, offsets whole cm within -100..100
function preset.value(key, v)
    if type(v) ~= "number" or v ~= v then return nil end
    if key == "fov_default" or key == "fov_ads" then return clamp_fov(v) end
    v = math.floor(math.max(-100, math.min(100, v)) + 0.5)
    if v == 0 then return nil end
    return v
end

function preset.save(i)
    if type(cfg.presets) ~= "table" then cfg.presets = {} end
    local p = { saved = true }
    for _, k in ipairs(preset.FIELDS) do p[k] = cfg[k] end
    cfg.presets["p" .. i] = p
    save()
end

function preset.load(i)
    local p = preset.get(i)
    if p == nil then return end
    preset.fov_ease = { def = cfg.fov_default, ads = cfg.fov_ads, t = 0 }
    for _, k in ipairs(preset.FIELDS) do cfg[k] = preset.value(k, p[k]) end
    cam_reset_request = true -- the offsets ease over like the toggle
    dirty, dirty_frames = false, 0
    save()
end

function preset.clear(i)
    if type(cfg.presets) == "table" then cfg.presets["p" .. i] = nil end
    save()
end

-- next item on the same row, at the row's top (y), so buttons after a lowered text line up
function preset.same_row(y)
    imgui.same_line()
    local q = cursor_pos()
    if q and y then set_pos(q.x, y) end
end

-- a fresh right-click on the item drawn just before (ImGui's own check when REFramework has it,
-- otherwise the right mouse button going down while the item is hovered)
function preset.right_clicked()
    local hovered = false
    pcall(function() hovered = imgui.is_item_hovered() == true end)
    if not hovered then return false end
    if imgui.is_mouse_clicked then
        local ok, v = pcall(imgui.is_mouse_clicked, 1)
        if ok and type(v) == "boolean" then return v end
    end
    return preset.rmb_fresh
end

function preset.tooltip(text)
    local hovered = false
    pcall(function() hovered = imgui.is_item_hovered() == true end)
    if hovered and imgui.set_tooltip then pcall(imgui.set_tooltip, text) end
end

-- one slot square; returns "left", "right" or nil
function preset.slot_button(i)
    local saved = preset.get(i) ~= nil
    local n = saved and push_button_colors(preset.COLOR, preset.HOVER, preset.ACTIVE) or 0
    local label = tostring(i) .. "##slot" .. i
    local ok, clicked = pcall(imgui.button, label, Vector2f.new(preset.SLOT_WIDTH, 0))
    if not ok then clicked = imgui.button(label) end
    pop_colors(n)
    if saved then
        preset.tooltip("Slot " .. i .. ": left-click to load, right-click to overwrite or clear")
    else
        preset.tooltip("Slot " .. i .. " (empty): left-click to save the current settings")
    end
    if clicked then return "left" end
    if saved and preset.right_clicked() then return "right" end
    return nil
end

-- Reset all overrides: everything goes back to the game's own camera at once, your sliders and
-- offsets as well as the game value the mod remembers (read again from the camera as soon as it
-- shows the normal view; no aiming needed). Saved presets and the hotkey are kept.
local function force_reset()
    cfg.fov_default, cfg.fov_ads = nil, nil
    cfg.cam_offset, cfg.cam_offset_y = nil, nil
    cfg.aim_offset, cfg.aim_offset_y = nil, nil
    cfg.game_rest_raw = nil
    preset.fov_ease = nil         -- a preset load still easing in stops here
    game_default_v = SEED_DEFAULT_RAW
    game_ads_v = aim_for(game_default_v)
    normal_known = false          -- read again from the camera; knife handling waits for it

    -- offsets: every setting the mod has touched goes back to its original value now, no ease
    cam_restore_all()
    for _, g in pairs(cam_groups) do
        g.wanted, g.from, g.out, g.t = { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 }, 1
    end
    cam_reset_request = false

    force_request = true          -- field of view: the game's own value on the next frame
    dirty, dirty_frames = false, 0
    confirming_reset = false
    save()
end

re.on_draw_ui(function()
    if not imgui.tree_node("RE2R CAM CONTROLS") then return end

    local pushed = push_style()
    local changed

    -- enable
    changed, cfg.enabled = imgui.checkbox("Enable Overrides", cfg.enabled)
    if changed then save() end

    -- hotkey, on the same row, shown inside its button (F1-F12 only, Esc cancels)
    imgui.same_line()
    if waiting_for_key then
        local n = push_amber()
        imgui.button("Press F1-F12...##hotkey")
        pop_colors(n)
    else
        local n = push_green()
        local pressed = imgui.button("Toggle Hotkey: " .. key_name(cfg.toggle_key) .. "##hotkey")
        pop_colors(n)
        if pressed then
            waiting_for_key = true
        end
    end

    gap(GAP_AFTER_HOTKEY)

    -- field of view
    header("Field of View", true)
    local v = cfg.fov_default or v_to_h(game_default_v)
    changed, v = fov_row("Normal:", "fov_default", v)
    if changed then cfg.fov_default = clamp_fov(v); dirty = true end

    local a = cfg.fov_ads or v_to_h(game_ads_v)
    changed, a = fov_row("ADS:", "fov_ads", a)
    if changed then cfg.fov_ads = clamp_fov(a); dirty = true end

    -- offsets: normal view and aiming view, side by side per axis
    header("Camera Offset", false)
    offset_setting("Offset X:", "cam_offset")
    offset_setting("ADS-Offset X:", "aim_offset")
    offset_setting("Offset Y:", "cam_offset_y")
    offset_setting("ADS-Offset Y:", "aim_offset_y")

    if not detection_ok then
        imgui.text_colored("Menu detection unavailable: applying everywhere", 0xFF00FFFF)
    end

    -- presets: "Presets:" label in the labels column, slot squares from the bars column
    gap(GAP_BETWEEN_SECTIONS)
    do
        local rmb = reframework:is_key_down(0x02)
        preset.rmb_fresh = rmb and not preset.rmb_prev
        preset.rmb_prev = rmb
        if preset.menu and not preset.get(preset.menu) then preset.menu = nil end

        local p = cursor_pos()
        local y = p and p.y
        local label_w = 0
        for _, l in ipairs(ROW_LABELS) do label_w = math.max(label_w, text_w(l)) end
        if p then set_pos(p.x, p.y + FRAME_PADDING[2]) end
        imgui.text("Presets:")
        imgui.same_line()
        if p then set_pos(p.x + label_w + LABEL_GAP, p.y) end

        if preset.menu then
            -- right-click row: "Slot #:" then Overwrite / Clear (amber) and Cancel
            local i = preset.menu
            local q = cursor_pos()
            if q then set_pos(q.x, q.y + FRAME_PADDING[2]) end
            imgui.text("Slot " .. i .. ":")
            preset.same_row(y)
            local n = push_amber()
            local overwrite = imgui.button("Overwrite##slotmenu")
            preset.same_row(y)
            local clear = imgui.button("Clear##slotmenu")
            pop_colors(n)
            preset.same_row(y)
            local cancel = imgui.button("Cancel##slotmenu")
            if overwrite then
                preset.save(i)
                preset.menu = nil
            elseif clear then
                preset.clear(i)
                preset.menu = nil
            elseif cancel then
                preset.menu = nil
            end
        else
            for i = 1, preset.COUNT do
                if i > 1 then preset.same_row(y) end
                local r = preset.slot_button(i)
                if r == "left" then
                    if preset.get(i) then preset.load(i) else preset.save(i) end
                elseif r == "right" then
                    preset.menu = i
                end
            end
        end
    end

    gap(GAP_BEFORE_RESETS)

    -- reset (two steps: Reset all overrides, then Confirm or Cancel; Esc cancels):
    -- everything back to the game's own camera at once, your sliders and offsets as well as the
    -- game value the mod remembers
    if confirming_reset then
        local n = push_amber()
        local confirm = imgui.button("Confirm##reset")
        pop_colors(n)
        imgui.same_line()
        local cancel = imgui.button("Cancel##reset")
        if confirm then
            force_reset()
            confirming_reset = false
        elseif cancel then
            confirming_reset = false
        end
    else
        local n = push_danger()
        local pressed = imgui.button("Reset all overrides##reset")
        pop_colors(n)
        if pressed then
            confirming_reset = true
        end
    end

    gap(1)

    pop_style(pushed)
    imgui.tree_pop()
end)