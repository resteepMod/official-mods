-- Yard Sale: crash on purpose and score the wreck. Every hit the game counts while the rider tumbles
-- (resteep.on("impact"): the body part, how hard, the surface) scores, more for the head and for trees, rocks and
-- buildings; a body part that takes enough is bruised, then broken (a bonus each). While the rider is down a
-- see-through skeleton shows on the body (resteep.rider.bones, drawn over the picture: white, bruised yellow,
-- broken red); when the ragdoll is over a card shows the score and what broke, the personal best is kept and the
-- score goes to the server's board "yard_sale" (one for everyone, higher is better).
-- Needs a ReSteep with the impact event and rider.bones (2026-11-17); without them the mod says so once.

-- points per unit of the game's hit amount, by body part and by surface (unknown parts and surfaces: 1)
local PART_MULT = {head = 2.0, body = 1.0, left_arm = 1.2, right_arm = 1.2, left_leg = 1.0, right_leg = 1.0, legs = 1.0}
local SURFACE_MULT = {tree = 1.5, branch = 1.2, rock = 1.5, wood_hard = 1.3, wood_thin = 1.3, metal_hard = 1.4,
                      concrete = 1.4, ice = 1.2}
local SURFACE_NAMES = {tree = "tree", branch = "branch", rock = "rock", wood_hard = "wood", wood_thin = "wood",
                       metal_hard = "metal", concrete = "concrete", ice = "ice"}
local POINTS = 10                                  -- per unit of amount
local BRUISED, BROKEN = 12, 35                     -- a part's summed amount for each state
local BREAK_BONUS = 1000                           -- per broken part (the head counts double)
local EARLY = 0.4                                  -- s: hits just before the crash event count (the collision itself)
local BOARD = "yard_sale"

-- the parts the card names, and which skeleton segments each colours
local PART_NAMES = {head = "skull", body = "pelvis and ribs", left_arm = "left arm", right_arm = "right arm",
                    left_leg = "left leg", right_leg = "right leg"}
local SEGMENTS = {                                 -- {from bone, to bone, part}
    {"Hips", "Spine", "body"}, {"Spine", "Spine1", "body"}, {"Spine1", "Spine2", "body"},
    {"Spine2", "Neck", "head"}, {"Neck", "Neck1", "head"}, {"Neck1", "Head", "head"},
}
for _, s in ipairs({"Left", "Right"}) do
    local arm, leg = s:lower() .. "_arm", s:lower() .. "_leg"
    for _, seg in ipairs({{"Spine2", s .. "Shoulder", arm}, {s .. "Shoulder", s .. "Arm", arm},
                          {s .. "Arm", s .. "ForeArm", arm}, {s .. "ForeArm", s .. "Hand", arm},
                          {"Hips", s .. "UpLeg", "body"}, {s .. "UpLeg", "L_" .. s .. "Leg", "body"},
                          {"L_" .. s .. "Leg", s .. "Foot", leg}, {s .. "Foot", s .. "ToeBase", leg}}) do
        SEGMENTS[#SEGMENTS + 1] = seg
    end
end
local COLOR = {ok = "#C8FFFFFF", bruised = "#FFFFD34E", broken = "#FFFF3B30"}

local function setting(key, default)
    local ok, v = pcall(resteep.config.get, key)
    if not ok or v == nil then return default end
    return v
end

local supported = type(resteep.rider.bones) == "function"
local best = (resteep.load() or {}).best or 0
local recent = {}                                  -- impacts before a crash: {t, info}
local run = nil                                    -- the crash being scored
local card = nil                                   -- the result card: {until_, lines, top}
local popups = {}                                  -- {text, x, y, z, until_, color}
local last = {speed = 0, airtime = 0}              -- the rider while riding (the crash event's speed is the last frame's)

local function state_of(dmg)
    if dmg >= BROKEN then return "broken" elseif dmg >= BRUISED then return "bruised" end
    return "ok"
end

local function new_run(info)
    return {start = resteep.time(), score = 0, hits = 0, damage = {}, broken = {}, bonus = 0,
            speed = info and info.speed or last.speed, air = info and info.air == 1, airtime = last.airtime,
            path = 0, from = nil, surfaces = {}}
end

local function add_damage(part, amount)
    local parts = part == "legs" and {"left_leg", "right_leg"} or {part}
    for _, p in ipairs(parts) do
        if PART_NAMES[p] then
            local before = state_of(run.damage[p] or 0)
            run.damage[p] = (run.damage[p] or 0) + (part == "legs" and amount / 2 or amount)
            if before ~= "broken" and state_of(run.damage[p]) == "broken" then
                local bonus = BREAK_BONUS * (p == "head" and 2 or 1)
                run.broken[#run.broken + 1] = PART_NAMES[p]
                run.bonus = run.bonus + bonus
                resteep.notify(string.format("Broken: %s  +%d", PART_NAMES[p], bonus), 2)
            end
        end
    end
end

local function score_hit(info)
    local amount = tonumber(info.amount) or 0
    if amount <= 0 then return end
    local pts = math.floor(amount * POINTS * (PART_MULT[info.part] or 1) * (SURFACE_MULT[info.material] or 1) + 0.5)
    run.score, run.hits = run.score + pts, run.hits + 1
    if SURFACE_NAMES[info.material] then run.surfaces[SURFACE_NAMES[info.material]] = true end
    add_damage(info.part, amount)
    if info.x then
        local where = SURFACE_NAMES[info.material] and (" " .. SURFACE_NAMES[info.material]) or ""
        popups[#popups + 1] = {text = string.format("+%d %s%s", pts, (PART_NAMES[info.part] or tostring(info.part)),
                                                    where),
                               x = info.x, y = info.y, z = info.z + 0.4, until_ = resteep.time() + 1.2,
                               color = (info.part == "head" or SURFACE_MULT[info.material]) and "#FFFF8A3D" or "#FFFFFFFF"}
    end
end

-- the score of a run: the hits, the broken parts, how fast it started, how far and how long it tumbled
local function total(r)
    local secs = resteep.time() - r.start
    local t = {hits = r.score, broken = r.bonus, speed = math.floor(r.speed * 3.6 * 5 + 0.5),
               air = r.air and math.floor(200 + r.airtime * 300 + 0.5) or 0,
               tumble = math.floor(r.path * 8 + 0.5), time = math.floor(secs * 40 + 0.5)}
    t.total = t.hits + t.broken + t.speed + t.air + t.tumble + t.time
    return t, secs
end

local function show_card(r)
    local t, secs = total(r)
    local lines = {
        {string.format("YARD SALE   %d", t.total), "#FFFFD34E", 1.4},
        {string.format("hits %d (%d)   broken %d", t.hits, r.hits, t.broken), "#FFFFFFFF"},
        {string.format("speed %d   air %d   tumble %d m: %d   down %.1f s: %d", t.speed, t.air, math.floor(r.path),
                       t.tumble, secs, t.time), "#FFDDDDDD"},
    }
    if #r.broken > 0 then lines[#lines + 1] = {"broken: " .. table.concat(r.broken, ", "), "#FFFF3B30"} end
    local hit = {}
    for s in pairs(r.surfaces) do hit[#hit + 1] = s end
    if #hit > 0 then table.sort(hit) lines[#lines + 1] = {"hit: " .. table.concat(hit, ", "), "#FFFF8A3D"} end
    if t.total > best then
        best = t.total
        resteep.save({best = best})
        lines[#lines + 1] = {"new personal best!", "#FF7CFC00"}
    else
        lines[#lines + 1] = {string.format("personal best %d", best), "#FFBBBBBB"}
    end
    card = {until_ = resteep.time() + setting("card_seconds", 8), lines = lines, top = nil, damage = r.damage}
    if setting("board", true) and t.total > 0 then
        local mine = card
        resteep.post("/mods/board/submit", {board = BOARD, value = t.total, lower_is_better = false, limit = 5,
                                            detail = {broken = #r.broken, hits = r.hits}},
            function(ok, reply)
                if not ok or type(reply) ~= "table" or card ~= mine then return end
                local top = {}
                for i, e in ipairs(reply.top or {}) do top[i] = string.format("%d. %s  %d", i, tostring(e.name), e.value) end
                if reply.rank then top[#top + 1] = string.format("you: #%d", reply.rank) end
                mine.top = top
            end)
    end
end

local function draw_skeleton(damage)
    if not setting("skeleton", true) then return end
    local bones = resteep.rider.bones()
    if not bones then return end
    local screen = {}
    for name, b in pairs(bones) do
        local x, y = resteep.project(b.x, b.y, b.z)
        if x then screen[name] = {x, y} end
    end
    for _, s in ipairs(SEGMENTS) do
        local a, b = screen[s[1]], screen[s[2]]
        if a and b then
            local st = state_of(damage[s[3]] or 0)
            resteep.line(a[1], a[2], b[1], b[2], COLOR[st], st == "ok" and 2 or 4)
        end
    end
    local h = screen.Head
    if h then
        local st = state_of(damage.head or 0)
        resteep.box(h[1] - 0.006, h[2] - 0.01, 0.012, 0.02, COLOR[st])
    end
end

resteep.on("impact", function(info)
    if not supported then return end
    if run then score_hit(info) return end
    recent[#recent + 1] = {t = resteep.time(), info = info}
    while #recent > 8 do table.remove(recent, 1) end
end)

resteep.on("crash", function(info)
    if not supported then return end
    run, card, popups = new_run(info), nil, {}
    local now = resteep.time()
    for _, r in ipairs(recent) do
        if now - r.t <= EARLY then score_hit(r.info) end      -- the hit that started it
    end
    recent = {}
end)

resteep.on("crash_end", function()
    if not run then return end
    show_card(run)
    run = nil
end)

resteep.on("world_leave", function() run, card, popups, recent = nil, nil, {}, {} end)

local said = false
resteep.on("frame", function()
    if not supported then
        if not said then
            said = true
            resteep.notify("Yard Sale needs a newer ReSteep (the impact event and rider.bones)", 5)
        end
        return
    end
    local now = resteep.time()
    if not run then
        local p = resteep.player()
        if p then                                  -- the air time counts for a moment after landing (a bad landing)
            last.speed = p.speed or last.speed
            if p.air then last.airtime, last.landed = p.airtime or 0, nil
            elseif not last.landed then last.landed = now
            elseif now - last.landed > 0.5 then last.airtime = 0 end
        end
    else
        local b = resteep.rider.bone and resteep.rider.bone("Hips")
        if b then
            if run.from then
                local dx, dy, dz = b.x - run.from.x, b.y - run.from.y, b.z - run.from.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d < 20 then run.path = run.path + d end     -- (a jump in the reading: a respawn, not a tumble)
            end
            run.from = {x = b.x, y = b.y, z = b.z}
        end
        draw_skeleton(run.damage)
        local t = total(run)
        resteep.text(0.5, 0.12, string.format("YARD SALE  %d", t.total), "#FFFFD34E", 1.6)
    end
    for i = #popups, 1, -1 do
        local pu = popups[i]
        if now > pu.until_ then
            table.remove(popups, i)
        else
            local x, y = resteep.project(pu.x, pu.y, pu.z + (1.2 - (pu.until_ - now)) * 0.6)
            if x then resteep.text(x, y, pu.text, pu.color) end
        end
    end
    if card then
        if now > card.until_ then card = nil return end
        draw_skeleton(card.damage)
        local n = #card.lines + (card.top and #card.top + 1 or 0)
        resteep.box(0.66, 0.24, 0.32, 0.05 + 0.032 * n, "#B0000000")
        local y = 0.27
        for _, l in ipairs(card.lines) do
            resteep.text(0.82, y, l[1], l[2], l[3])
            y = y + (l[3] and 0.045 or 0.032)
        end
        if card.top then
            y = y + 0.01
            for _, l in ipairs(card.top) do resteep.text(0.82, y, l, "#FFFFD34E") y = y + 0.032 end
        end
    end
end)
