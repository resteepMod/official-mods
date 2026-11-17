-- World editor, client half: the panel on the MODS page and the free camera with Blender's keys, in sandboxed Lua
-- (the overlay runs it; README.md describes the editor). Where the player is (position, map cell), the objects near
-- them (the map's index, which the world editor's session step builds from the player's own install at game start
-- and puts beside the game: resteep.data), adding copies of placeable props, moving / turning / scaling / removing
-- objects, the list of edits with undo and authors, the server's rules. Edits go to the server half (mod.lua,
-- /_powder/world_editor/, resteep.http), which keeps them; the session helper turns them into cells that the
-- overlay serves and makes the game read again at once (resteep.world.live). While a tool runs, the object itself
-- follows it (resteep.prop: the live preview), placed the way world.py apply will place it from the edit.
--
-- "In front" is the direction the rider last moved in. The index is parsed over several frames (a coroutine: the
-- Alps' 24,000 objects are 4 MB of text), the edit list is folded only when it changes, and the objects near a
-- point are looked up in 128 m buckets and kept for a moment: each call stays well inside the frame's time budget.

local ui = resteep.ui
local floor, sqrt, abs, sin, cos, tan, atan, asin = math.floor, math.sqrt, math.abs, math.sin, math.cos, math.tan,
    math.atan, math.asin
local min, max, rad, deg = math.min, math.max, math.rad, math.deg
local fmt, find, sub = string.format, string.find, string.sub

local MAPS = {"Alpes", "Japan", "Alaska", "WhiteRoom"}
local BASE = "/_powder/world_editor/"
-- placeable props listed first (parts of the prop name, any case): trees, rocks, kickers and ramps, things to sit
-- on, round objects to ride into
local FAVOURITES = {"sapin", "rock_", "kick", "quarterpipe", "bigair", "ramp", "platform", "bench", "snowman",
                    "barrel", "rabbid", "table", "woodpile", "trunkpile", "haycart", "parasol", "transat", "balloon",
                    "baloon"}
local BUCKET = 128                      -- metres: the objects near a point are looked up in squares of this size
local LINES_PER_STEP = 500              -- index lines parsed per frame (~3 ms here; the call budget is 20 ms)
local MAX_EDITS_SHOWN = 150
local GONE = "drawn only"

local function clamp(v, lo, hi) return v < lo and lo or v > hi and hi or v end
local function r3(v) return floor(v * 1000 + 0.5) / 1000 end       -- JSON without float noise
local function hex(v) return fmt("0x%x", v) end
local function v3(p) return {p[1], p[2], p[3]} end
local function vadd(a, b, k) k = k or 1; return {a[1] + b[1] * k, a[2] + b[2] * k, a[3] + b[3] * k} end
local function vsub(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
local function vlen(a) return sqrt(dot(a, a)) end
local function vtab(v) return {x = v[1], y = v[2], z = v[3]} end

-- one shipped object of a map (ids are < 2^42, cells < 2^17)
local function obj_key(layer, cell, id)
    return ((floor(cell) & 0x1FFFF) << 44) | ((floor(layer) & 3) << 42) | (floor(id) & ((1 << 42) - 1))
end

-- ---- the live preview's matrices (tests/test_world_editor_preview.py checks them against world.py) ---------------
-- 16 numbers, row-major as the engine and world.py keep them: rows 1-3 the object's axes in the world (their lengths
-- its scale), row 4 its origin. Turns and scales are about the origin; a move sets it (the edit's absolute position).
local P = {}
function P.moved(cur, to)
    local out = {table.unpack(cur)}
    out[13], out[14], out[15] = to[1], to[2], to[3]
    return out
end
-- `d` degrees about the unit axis `a` through the origin, right-handed (world.py about(cur, mat_rot_axis(a, d)))
function P.turned(cur, a, d)
    local t = rad(d)
    local c, s = cos(t), sin(t)
    local out = {table.unpack(cur)}
    for r = 0, 2 do
        local v = {cur[4 * r + 1], cur[4 * r + 2], cur[4 * r + 3]}
        local x, d0 = cross(a, v), dot(a, v)
        for k = 1, 3 do out[4 * r + k] = v[k] * c + x[k] * s + a[k] * d0 * (1 - c) end
    end
    return out
end
-- the object's own axis k (1 x, 2 y, 3 z) as its matrix has it, made unit (world.py turns_delta, local = true)
function P.own_axis(cur, k)
    local v = {cur[4 * (k - 1) + 1], cur[4 * (k - 1) + 2], cur[4 * (k - 1) + 3]}
    local l = vlen(v)
    if not (l > 1e-6) then return nil end
    return {v[1] / l, v[2] / l, v[3] / l}
end
function P.scaled(cur, f)
    local out = {table.unpack(cur)}
    for r = 0, 2 do for k = 1, 3 do out[4 * r + k] = cur[4 * r + k] * f end end
    return out
end
-- a group's member (world.py transform_object: the member's matrix times the group's delta): moved by `d`, turned
-- `deg` about the unit axis `a` through the group's origin `p`, scaled by `f` about it
function P.shifted(cur, d)
    local out = {table.unpack(cur)}
    out[13], out[14], out[15] = cur[13] + d[1], cur[14] + d[2], cur[15] + d[3]
    return out
end
function P.turned_about(cur, p, a, deg_)
    local out = P.turned(cur, a, deg_)
    local o = P.turned({cur[13] - p[1], cur[14] - p[2], cur[15] - p[3], 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1}, a, deg_)
    out[13], out[14], out[15] = p[1] + o[1], p[2] + o[2], p[3] + o[3]
    return out
end
function P.scaled_about(cur, p, f)
    local out = P.scaled(cur, f)
    out[13], out[14], out[15] = p[1] + (cur[13] - p[1]) * f, p[2] + (cur[14] - p[2]) * f, p[3] + (cur[15] - p[3]) * f
    return out
end
-- a group's own axis k from its yaw (the index has no tilt for groups): x and y turned about Z, z up
function P.yawed_axis(yaw, k)
    local c, s_ = cos(rad(yaw)), sin(rad(yaw))
    return ({{c, s_, 0}, {-s_, c, 0}, {0, 0, 1}})[k]
end
-- what resteep.prop.set takes: finite, |values| <= 20000, each axis row 0.01 .. 100 long
function P.valid(m)
    for i = 1, 16 do
        local v = m[i]
        if v ~= v or abs(v) > 20000 then return false end
    end
    for r = 0, 2 do
        local l = sqrt(m[4 * r + 1] ^ 2 + m[4 * r + 2] ^ 2 + m[4 * r + 3] ^ 2)
        if l < 0.01 or l > 100 then return false end
    end
    return true
end
function P.close(a, b, tol)
    for i = 1, 15 do if not (abs(a[i] - b[i]) <= tol) then return false end end
    return true
end

-- ---- the map index (world.py index, beside the game: <Map>.tsv) -----------------------------------------------
local IX = {}                           -- map -> index (loading or loaded)
local MODELS                            -- content mods' models: name -> {lo, size} (models.tsv)
local CONTENT                           -- content mods' world edits (content_edits.json), in front of the player's

local function grid_side(g, level) return 1 << (g.levels - 1 - level) end
local function grid_first(g, level)
    local n = 0
    for k = 0, level - 1 do n = n + grid_side(g, k) ^ 2 end
    return floor(n)
end
local function grid_at(g, x, y, level)
    local size = g.cell * (1 << level)
    local col, row, s = floor((x - g.min_x) / size), floor((y - g.min_y) / size), grid_side(g, level)
    if col >= 0 and col < s and row >= 0 and row < s then return grid_first(g, level) + row * s + col end
    return -1
end
-- index -> level, x0, y0, size of its square
local function grid_rect(g, index)
    for level = 0, g.levels - 1 do
        local s = grid_side(g, level)
        if index < s * s then
            local size = g.cell * (1 << level)
            return level, g.min_x + (index % s) * size, g.min_y + (index // s) * size, size
        end
        index = index - s * s
    end
end
-- the finest cell of the main table at (x, y) that exists (where world.py apply puts an added object), or -1
local function target_cell(ix, x, y)
    for level = 0, ix.grid.levels - 1 do
        local i = grid_at(ix.grid, x, y, level)
        if i >= 0 and ix.cells0[i] then return i, level end
    end
    return -1
end
local function bucket(x, y) return (floor(x / BUCKET) + 32768) * 65536 + floor(y / BUCKET) + 32768 end

local F = "([^\t\r\n]*)"
local OBJ_PAT = "^obj\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t"
    .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "([^\r\n]*)"
local LO_PAT = "^\t" .. F .. "\t" .. F .. "\t" .. F
local MEMBERS_PAT = "^\t[^\t]*\t[^\t]*\t[^\t]*\t([0-9a-fx,]+)"   -- index v3: a group's member entities after lo
local GRID_PAT = "^grid\t0\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F

-- parses ix.map's index; a coroutine: yields every LINES_PER_STEP lines
local function load_index(ix)
    local data, why = resteep.data.read(ix.map .. ".tsv")
    if not data then
        ix.error = "no index for " .. ix.map .. " (the world editor's session step builds it at game start: "
            .. tostring(why) .. ")"
        return
    end
    coroutine.yield()
    local L = ix
    local tn, n, pos, lines, size = tonumber, 0, 1, 0, #data
    while pos <= size do
        local e = find(data, "\n", pos, true) or size + 1
        local tag = sub(data, pos, pos + 3)
        if tag == "obj\t" then
            local _, _, layer, cell, id, kind, x, y, z, yaw, scale, sx, sy, sz, name, prop, rest = find(data, OBJ_PAT, pos)
            if layer then
                n = n + 1
                L.layer[n], L.cell[n], L.id[n] = tn(layer) or 0, tn(cell) or 0, tn(id) or 0
                L.group[n] = kind == "group"
                L.x[n], L.y[n], L.z[n] = tn(x) or 0, tn(y) or 0, tn(z) or 0
                L.yaw[n], L.scale[n] = tn(yaw) or 0, tn(scale) or 1
                local a, b, c = tn(sx) or 0, tn(sy) or 0, tn(sz) or 0
                L.sx[n], L.sy[n], L.sz[n] = a, b, c
                L.name[n], L.prop[n] = name, prop
                if kind == "group" then                    -- v3: the live preview moves a group by its members
                    local _, _, ms = find(rest, MEMBERS_PAT)
                    if ms then
                        local list = {}
                        for h in ms:gmatch("0x%x+") do list[#list + 1] = tn(h) end
                        if #list > 0 then L.members[n] = list end
                    end
                end
                local _, _, lx, ly, lz = find(rest, LO_PAT)
                if lx then                                 -- index v2: the box's low corner
                    L.lx[n], L.ly[n], L.lz[n] = tn(lx) or 0, tn(ly) or 0, tn(lz) or 0
                else                                       -- v1: around the origin, from the ground up
                    L.lx[n], L.ly[n], L.lz[n] = -a / 2, -b / 2, 0
                end
            end
        elseif tag == "cell" then
            local _, _, layer, idx = find(data, "^cell\t(%d+)\t(%d+)", pos)
            if layer == "0" then ix.cells0[tn(idx)] = true end
        elseif tag == "grid" then
            local _, _, gx, gy, gc, gl = find(data, GRID_PAT, pos)
            if gx then ix.grid = {min_x = tn(gx) or 0, min_y = tn(gy) or 0, cell = tn(gc) or 128,
                                  levels = clamp(floor(tn(gl) or 1), 1, 12)} end
        end
        pos = e + 1
        lines = lines + 1
        if lines % LINES_PER_STEP == 0 then coroutine.yield() end
    end
    data = nil
    ix.n = n
    if not ix.grid then ix.error = "the index has no grid line"; return end
    -- placeable props: entities with a prop template (world.py copies entities only); one example each, from the
    -- finest level (small cells stream with what is around them)
    local level0 = grid_side(ix.grid, 0) ^ 2
    local by_prop = {}
    for i = 1, n do
        local key = obj_key(L.layer[i], L.cell[i], L.id[i])
        ix.key[i] = key
        ix.by_key[key] = i
        local b = bucket(L.x[i], L.y[i])
        local list = ix.buckets[b]
        if not list then list = {}; ix.buckets[b] = list end
        list[#list + 1] = i
        local pr = L.prop[i]
        if not L.group[i] and pr ~= "" then
            local p = by_prop[pr]
            if not p then
                p = {name = pr, count = 0, example = i, fav = false}
                local l = pr:lower()
                for _, f in ipairs(FAVOURITES) do if find(l, f, 1, true) then p.fav = true; break end end
                by_prop[pr] = p
                ix.props[#ix.props + 1] = p
            end
            p.count = p.count + 1
            if L.cell[p.example] >= level0 and L.cell[i] < level0 then p.example = i end
        end
        if i % (LINES_PER_STEP * 3) == 0 then coroutine.yield() end
    end
    for _, p in ipairs(ix.props) do
        local x = p.example
        p.label = fmt("%s%s  (%.0fx%.0fx%.0f m, %d placed)", p.fav and "* " or "", p.name, L.sx[x], L.sy[x], L.sz[x], p.count)
        p.lower = p.name:lower()
    end
    table.sort(ix.props, function(a, b)
        if a.fav ~= b.fav then return a.fav end
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
end

local function new_index(map)
    local ix = {map = map, n = 0, cells0 = {}, by_key = {}, key = {}, buckets = {}, props = {}, done = false,
                layer = {}, cell = {}, id = {}, group = {}, x = {}, y = {}, z = {}, yaw = {}, scale = {},
                sx = {}, sy = {}, sz = {}, lx = {}, ly = {}, lz = {}, name = {}, prop = {}, members = {}}
    ix.co = coroutine.create(function() load_index(ix) end)
    return ix
end

-- content mods' models (models.tsv) and world edits (content_edits.json), written by the session step
local function load_content()
    MODELS, CONTENT = {}, {}
    local text = resteep.data.read("models.tsv")
    for line in (text or ""):gmatch("[^\r\n]+") do
        local _, _, name, a, b, c, d, e, f = find(line, "^model\t" .. F .. "\t" .. F .. "\t" .. F .. "\t" .. F .. "\t"
            .. F .. "\t" .. F .. "\t" .. F)
        if name then
            local lo = {tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0}
            MODELS[name] = {lo = lo, size = {max(0, (tonumber(d) or 0) - lo[1]), max(0, (tonumber(e) or 0) - lo[2]),
                                             max(0, (tonumber(f) or 0) - lo[3])}}
        end
    end
    local j = resteep.data.json("content_edits.json")
    if type(j) == "table" and type(j.edits) == "table" then CONTENT = j.edits end
end

-- ---- state ----------------------------------------------------------------------------------------------------
local S = {
    map = 1, map_chosen = false,
    status = "asking the server for the edits...", busy = false,
    edits = {}, ver = 0, rules = nil, asked = false,
    filter = "", favs_only = false, prop = nil,     -- prop: the chosen placeable prop (its table)
    ahead = 6, dz = 0, add_yaw = 0, add_scale = 1, on_ground = true,
    radius = 40, all_kinds = false,
    sel = "", sel_pos = {0, 0, 0}, turn = 15, factor = 1.25,
    clear_ask = false,
    me = {0, 0, 0}, have_pos = false, heading = 0, have_heading = false, anchor = nil,
    edit = false, hotkey = false, note = "", delete_armed = "", delete_until = 0, select_newest = false,
    rules_seen = nil, r_mode = 1, r_undo = true, r_shipped = true, r_adds = 0, r_edits = 0,
}
local W = {changes = {}, added = {}}    -- the edit list folded for the selected map (fold)
local W_dirty = true
local sent = {}                         -- replies to edits the live preview showed: {token, ok, n}
local pressed = {}                      -- the keys pressed this frame (the key event)
local near_cache = {}

local function map_name() return MAPS[S.map] end
-- the map the game is in (its world "STP_<Map>"), or nil (a menu, loading, another world)
local function world_map()
    local w = resteep.world.name()
    for i, m in ipairs(MAPS) do if w == "STP_" .. m then return i end end
end
local function set_map(i)
    if i == S.map then return end
    S.map, S.sel, S.prop, W_dirty = i, "", nil, true
end
local function cur_ix()
    local ix = IX[map_name()]
    return ix and ix.done and ix or nil
end

-- ---- the server (mod.lua) -----------------------------------------------------------------------------------------
local function on_reply(status, reply, what, token)
    S.busy = false
    local t = type(reply) == "table" and reply or nil
    if token then
        local ok = status == 200 and t and type(t.edits) == "table" and (t.next or 0) > 0
        sent[#sent + 1] = {token = token, ok = ok, n = ok and t.next - 1 or 0}
    end
    if status == 200 and t and t.undo_others ~= nil then        -- the rules (GET / POST rules)
        S.rules = t
        S.status = what .. ": ok"
    elseif status == 200 and t and type(t.edits) == "table" then
        S.edits = t.edits
        S.ver = S.ver + 1
        W_dirty = true
        S.list_changed = true
        S.status = fmt("%s: ok (%d edit(s) stored)", what, #t.edits)
        if not S.map_chosen and not world_map() and #S.edits > 0 then   -- not in a world: the newest edit's map
            local m = S.edits[#S.edits].map
            for i, name in ipairs(MAPS) do if name == m then set_map(i) end end
        end
        if what ~= "load" then resteep.world.live_poke() end   -- the live helper asks for the list now
    elseif status == 0 then
        S.status = what .. ": no reply from the server"
    else
        local err = t and type(t.error) == "string" and t.error
            or status == 404 and "not found (the server runs no mods/world_editor: needs the Rust server)"
            or "HTTP " .. tostring(status)
        S.status = what .. ": " .. err
    end
end

-- token: an edit the live preview showed already (its reply comes back in `sent`)
local function request(method, action, body, what, token)
    S.busy = true
    S.status = what .. "..."
    local ok, why = resteep.http(method, BASE .. action, body, function(status, reply)
        on_reply(status, reply, what, token)
    end)
    if not ok then
        S.busy = false
        S.status = what .. ": " .. tostring(why)
        if token then sent[#sent + 1] = {token = token, ok = false, n = 0} end
    end
end

-- ---- the edit list folded into what the world will look like (as world.py apply folds it) ------------------------
local function num(e, k, d) local v = e[k]; return type(v) == "number" and v or d end
local function pos_of(e)
    local p = e.pos
    if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and type(p[3]) == "number" then
        return {p[1], p[2], p[3]}
    end
end

local function fold_one(w, e)
    local op, n = e.op, e.n or 0
    local model = op == "add" and type(e.model) == "string"
    if op == "add" and (model or type(e.src) == "table") then
        local a = {n = n, name = type(e.name) == "string" and e.name or "", pos = pos_of(e) or {0, 0, 0},
                   yaw = num(e, "yaw", 0), scale = num(e, "scale", 1), tilted = false}
        if model then
            a.model = e.model
            if a.name == "" then a.name = a.model end
        else
            a.src_layer, a.src_cell = num(e.src, "layer", 0), num(e.src, "cell", 0)
            a.src_id = type(e.src.id) == "string" and e.src.id or ""
        end
        w.added[n] = a
        return
    end
    local ch, ad
    if type(e.of) == "number" then
        ad = w.added[e.of]
        if not ad then return end
    elseif type(e.obj) == "table" then
        local o = e.obj
        local key = obj_key(num(o, "layer", 0), num(o, "cell", 0), tonumber(o.id or "") or 0)
        ch = w.changes[key]
        if not ch then
            ch = {moved = false, pos = {0, 0, 0}, yaw = 0, scale = 1, removed = false, tilted = false}
            w.changes[key] = ch
        end
        if ch.removed then return end
    else
        return
    end
    local t = ch or ad
    if op == "move" then
        local p = pos_of(e)
        if p then t.pos = p; if ch then ch.moved = true end end
    elseif op == "turn" then
        t.yaw = t.yaw + num(e, "deg", 0)
    elseif op == "rotate" then                           -- the boxes follow turns about Z only (a tilt: G)
        if e.axis == "z" and not e["local"] then t.yaw = t.yaw + num(e, "deg", 0) end
        t.tilted = t.tilted or e.axis ~= "z"
    elseif op == "scale" then
        t.scale = t.scale * num(e, "factor", 1)
    elseif op == "remove" then
        if ch then ch.removed = true else w.added[ad.n] = nil end
    end                                                  -- "ground": its height comes from the terrain (world.py)
end

local function fold(edits, map)
    local w = {changes = {}, added = {}}
    for _, list in ipairs(edits) do
        for _, e in ipairs(list) do
            if type(e) == "table" and e.map == map then fold_one(w, e) end
        end
    end
    return w
end

-- ---- the objects near a point, as the edits leave them, with their boxes ------------------------------------------
-- The object's box in the world: the index's (around its origin, axis-aligned), turned by `dyaw` degrees and scaled
-- by `dscale` about the origin as an edit does, at `pos`; without a box, 1 m around the origin.
local function box_at(lo, size, dyaw, dscale, pos)
    if not lo or size[1] + size[2] + size[3] <= 0 then lo, size = {-0.5, -0.5, -0.5}, {1, 1, 1} end
    local c, s = cos(rad(dyaw)), sin(rad(dyaw))
    local blo, bhi = {1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}
    for k = 0, 7 do
        local x = lo[1] + ((k & 1) ~= 0 and size[1] or 0)
        local y = lo[2] + ((k & 2) ~= 0 and size[2] or 0)
        local z = lo[3] + ((k & 4) ~= 0 and size[3] or 0)
        local p = {(c * x - s * y) * dscale + pos[1], (s * x + c * y) * dscale + pos[2], z * dscale + pos[3]}
        for i = 1, 3 do blo[i] = min(blo[i], p[i]); bhi[i] = max(bhi[i], p[i]) end
    end
    return {lo = blo, hi = bhi}
end
local function box_of_index(ix, i, dyaw, dscale, pos)
    if not i then return box_at(nil, nil, dyaw, dscale, pos) end
    return box_at({ix.lx[i], ix.ly[i], ix.lz[i]}, {ix.sx[i], ix.sy[i], ix.sz[i]}, dyaw, dscale, pos)
end

-- one object as the panel and the tools use it: shipped (i: its index row, changed: an edit moved / turned / scaled
-- it) or added (n: its edit, i: its source, if indexed; model: a content mod's model)
local function shipped_row(ix, i, ch, c)
    local pos = ch and ch.moved and v3(ch.pos) or {ix.x[i], ix.y[i], ix.z[i]}
    local dyaw, dscale = ch and ch.yaw or 0, ch and ch.scale or 1
    local name = ix.name[i]
    return {i = i, pos = pos, yaw = ix.yaw[i] + dyaw, scale = ix.scale[i] * dscale, changed = ch ~= nil,
            dist = sqrt((pos[1] - c[1]) ^ 2 + (pos[2] - c[2]) ^ 2), name = name ~= "" and name or hex(ix.id[i]),
            key = "o:" .. ix.key[i], box = box_of_index(ix, i, dyaw, dscale, pos)}
end
local function added_row(ix, n, a, c)
    local src = a.model == nil and ix.by_key[obj_key(a.src_layer, a.src_cell, tonumber(a.src_id) or 0)] or nil
    local m = a.model and MODELS[a.model]
    return {added = true, n = n, i = src, pos = v3(a.pos), yaw = a.yaw, scale = a.scale,
            dist = sqrt((a.pos[1] - c[1]) ^ 2 + (a.pos[2] - c[2]) ^ 2), name = a.name ~= "" and a.name or a.src_id or "?",
            model = a.model, key = "a:" .. floor(n),
            box = m and box_at(m.lo, m.size, a.yaw, a.scale, a.pos) or box_of_index(ix, src, a.yaw, a.scale, a.pos)}
end

-- the object behind a selection key ("o:<obj_key>", "a:<edit n>") as the edits leave it, or nil (removed, gone)
local function row_for_key(key, c)
    local ix = cur_ix()
    if not ix or ix.error or key == "" then return nil end
    local kind, v = sub(key, 1, 1), tonumber(sub(key, 3))
    if not v then return nil end
    if kind == "a" then
        local a = W.added[v]
        return a and added_row(ix, v, a, c)
    end
    local i, ch = ix.by_key[v], W.changes[v]
    if not i or (ch and ch.removed) then return nil end
    return shipped_row(ix, i, ch, c)
end

-- The objects of the selected map within `radius` m of c (on the ground plane) as the edits leave them: shipped
-- ones (with a prop, or all), changed ones where the edits put them, added copies. Flat arrays, no table per object
-- (the free camera asks within 400 m: thousands in a village): kind (0 shipped as indexed, 1 changed, 2 added), ref
-- (index row or edit n), d2, and each one's box (lo x0 y0 z0, hi x1 y1 z1) for picking.
local function gather(c, radius, all)
    local g = {n = 0, kind = {}, ref = {}, d2 = {}, x0 = {}, y0 = {}, z0 = {}, x1 = {}, y1 = {}, z1 = {}}
    local ix = cur_ix()
    if not ix or ix.error then return g end
    local kind, ref, d2s, x0, y0, z0, x1, y1, z1 = g.kind, g.ref, g.d2, g.x0, g.y0, g.z0, g.x1, g.y1, g.z1
    local X, Y, Z, LX, LY, LZ, SX, SY, SZ = ix.x, ix.y, ix.z, ix.lx, ix.ly, ix.lz, ix.sx, ix.sy, ix.sz
    local prop, keys, changes = ix.prop, ix.key, W.changes
    local cx, cy, r2, n = c[1], c[2], radius * radius, 0
    local function add(k, r, d2, b)
        n = n + 1
        kind[n], ref[n], d2s[n] = k, r, d2
        x0[n], y0[n], z0[n], x1[n], y1[n], z1[n] = b.lo[1], b.lo[2], b.lo[3], b.hi[1], b.hi[2], b.hi[3]
    end
    for bx = floor((cx - radius) / BUCKET), floor((cx + radius) / BUCKET) do
        for by = floor((cy - radius) / BUCKET), floor((cy + radius) / BUCKET) do
            local list = ix.buckets[(bx + 32768) * 65536 + by + 32768]
            if list then
                for _, i in ipairs(list) do
                    local dx, dy = X[i] - cx, Y[i] - cy
                    local d2 = dx * dx + dy * dy
                    if d2 <= r2 and (all or prop[i] ~= "") and not changes[keys[i]] then
                        n = n + 1
                        kind[n], ref[n], d2s[n] = 0, i, d2
                        local sx, sy, sz = SX[i], SY[i], SZ[i]
                        if sx + sy + sz > 0 then
                            local ax, ay, az = X[i] + LX[i], Y[i] + LY[i], Z[i] + LZ[i]
                            x0[n], y0[n], z0[n], x1[n], y1[n], z1[n] = ax, ay, az, ax + sx, ay + sy, az + sz
                        else                             -- no box in the index: 1 m around the origin
                            x0[n], y0[n], z0[n] = X[i] - 0.5, Y[i] - 0.5, Z[i] - 0.5
                            x1[n], y1[n], z1[n] = X[i] + 0.5, Y[i] + 0.5, Z[i] + 0.5
                        end
                    end
                end
            end
        end
    end
    for key, ch in pairs(changes) do
        local i = ix.by_key[key]
        if i and not ch.removed and (all or prop[i] ~= "") then
            local row = shipped_row(ix, i, ch, c)
            if row.dist * row.dist <= r2 then add(1, i, row.dist * row.dist, row.box) end
        end
    end
    for k, a in pairs(W.added) do
        local d2 = (a.pos[1] - cx) ^ 2 + (a.pos[2] - cy) ^ 2
        if d2 <= r2 then add(2, k, d2, added_row(ix, k, a, c).box) end
    end
    g.n = n
    return g
end

local function row_of(g, k, c)
    local ix = cur_ix()
    if g.kind[k] == 2 then return added_row(ix, g.ref[k], W.added[g.ref[k]], c) end
    local i = g.ref[k]
    return shipped_row(ix, i, g.kind[k] == 1 and W.changes[ix.key[i]] or nil, c)
end

-- the `limit` nearest as rows, nearest first (sorted as whole numbers: d2 in 1/16 m² and the slot, no comparator)
local function nearest(g, c, limit)
    local order = {}
    for k = 1, g.n do order[k] = floor(g.d2[k] * 16) * 1048576 + k end
    table.sort(order)
    local rows = {}
    for j = 1, min(limit, g.n) do rows[j] = row_of(g, order[j] % 1048576, c) end
    return rows
end

-- kept for a moment (and until the list, the map or the question changes): the panel and the free camera ask
-- every frame
local function near(which, c, radius, all, step, make)
    local q = fmt("%s %d %d %d %d %s %d", map_name(), floor(c[1] / step), floor(c[2] / step), radius, S.ver,
                  tostring(all), W_dirty and 1 or 0)
    local e = near_cache[which]
    local now = resteep.time()
    if e and e.q == q and now - e.at < 1 then return e.v end
    local v = make(gather(c, radius, all))
    near_cache[which] = {q = q, at = now, v = v}
    return v
end

local function target_of(n)
    local j = {map = map_name()}
    if n.added then
        j.of = n.n
    else
        local ix = cur_ix()
        j.obj = {layer = ix.layer[n.i], cell = ix.cell[n.i], id = hex(ix.id[n.i]), name = ix.name[n.i]}
    end
    return j
end

-- the status line: green when the server took the last request, amber while one is on its way or it failed
local function status_color() return (not S.busy and find(S.status, ": ok", 1, true)) and "good" or "warn" end

local function jpos(p) return {r3(p[1]), r3(p[2]), r3(p[3])} end

local function edit_send(n, op, key, value, more, token)
    local j = target_of(n)
    j.op = op
    if key then j[key] = value end
    for k, v in pairs(more or {}) do j[k] = v end
    request("POST", "edits", j, op, token)
end

local function last_edit()
    local last = 0
    for _, e in ipairs(S.edits) do
        if type(e) == "table" and e.map == map_name() then last = max(last, e.n or 0) end
    end
    return last
end

local function ahead_of(dist)
    local h = S.have_heading and S.heading or math.pi / 2          -- unknown: +Y (north)
    return {S.me[1] + cos(h) * dist, S.me[2] + sin(h) * dist, S.me[3] + S.dz}
end

local function describe(e)
    local op = tostring(e.op or "?")
    local what = ""
    if op == "add" then what = tostring(e.name or "")
    elseif type(e.of) == "number" then what = fmt("added #%d", floor(e.of))
    elseif type(e.obj) == "table" then
        what = (e.obj.name and e.obj.name ~= "") and tostring(e.obj.name) or tostring(e.obj.id or "")
    end
    local extra = ""
    if op == "turn" then extra = fmt(" %+.0f deg", num(e, "deg", 0))
    elseif op == "ground" then extra = fmt(" %+.1f m", num(e, "offset", 0))
    elseif op == "scale" then extra = fmt(" x%.2f", num(e, "factor", 1)) end
    local p = pos_of(e)
    if (op == "move" or op == "add") and p then extra = fmt(" (%.1f, %.1f, %.1f)", p[1], p[2], p[3]) end
    local out = fmt("#%d %s %s%s", floor(e.n or 0), op, what, extra)
    if type(e.by_name) == "string" then out = out .. "  - " .. e.by_name end
    return out
end

-- ---- the live preview: the real object follows a running tool ----------------------------------------------------
-- G / R / S move the object itself every frame (resteep.prop: the engine's own transform update), from the matrices
-- it had when the tool began, the way world.py apply will place it from the edit. What moves ("parts"): a shipped
-- plain entity itself; an added copy by the id the helper says it got (live\adds.tsv); a shipped group by its member
-- entities (the index's members: the overlay moves entities, not groups), turned and scaled about the group's
-- origin as world.py does (each member's matrix times the group's delta). Cancel puts the matrices back; a confirm
-- sends the edit and leaves the parts where they are, which is where the edit puts them once their cell is read
-- again. The server refusing the edit, or the edit being undone (gone from the list), puts them back, unless
-- something else moved them since (a reloaded cell is right by itself). New props, models and what the overlay
-- refuses keep the drawn outline (or box) only. The engine moves objects in its own update, which a held world
-- skips: while an object follows the tool, or a move is still on its way, the world runs. A cell reload during the
-- tool does not end it: its objects are made anew, maybe at an older place, and the overlay puts an object this mod
-- holds back where the mod put it (liveobjects.cpp, live_rule.h). The mod lets an object go (resteep.prop.keep) once
-- nothing waits for it: no tool on it, no move on its way, and its edit is in the cells the helper serves
-- (resteep.world.live().edits; before that the helper's list is older than the preview).
local LV = {on = false, key = "", parts = {}, group = false, gen = 0, why = ""}
local previewed = {}                    -- {parts = {{id, before, after}}, token, n, at}: sent, shown already
local next_token = 1
local want = {}                         -- id -> {m, at}: what was set, until the object shows it (or 3 s)
local moved = {}                        -- id -> true: set by this mod and not let go yet (resteep.prop.keep)

local function live_gen()
    local l = resteep.world.live()
    return l and l.reloads or 0
end

-- the copy ids of add edits (live\adds.tsv: map, edit number, id), read again when the helper's generation changes
local ADDS = {gen = -1, ids = {}}
local function add_id(map, n)
    local l = resteep.world.live()
    local g = l and l.generation or 0
    if g ~= ADDS.gen then
        ADDS.gen, ADDS.ids = g, {}
        local data = resteep.data.read("live/adds.tsv")
        for m, k, id in (data or ""):gmatch("([^\t\n]+)\t(%d+)\t(0x%x+)") do
            ADDS.ids[m .. "#" .. k] = tonumber(id)
        end
    end
    return ADDS.ids[map .. "#" .. fmt("%d", floor(n))]   -- (an edit number from JSON is a float: 4.0)
end

local function live_get(id)
    local g = resteep.prop.get(id)
    return g and g.matrix or nil
end

local function live_current(id)
    local w = want[id]
    if w then return w.m end
    return live_get(id)
end

local function live_set(id, m)
    if not P.valid(m) or not resteep.prop.set(id, {matrix = m}) then return false end
    want[id] = {m = m, at = resteep.time()}
    moved[id] = true
    return true
end

-- the newest edit the helper's served cells hold (huge without live edits: nothing to wait for then)
local function live_edits()
    local l = resteep.world.live()
    return l and l.helper and l.edits or math.huge
end

-- the sets the game has done by now; an object nothing waits for any more is let go; true while the world must run
local function live_tick()
    local now = resteep.time()
    for id, w in pairs(want) do
        local m = live_get(id)
        if not m or P.close(m, w.m, 1e-3) or now - w.at > 3 then want[id] = nil end
    end
    if next(moved) then
        local waiting, done = {}, live_edits()
        if LV.on then for _, q in ipairs(LV.parts) do waiting[q.id] = true end end
        for _, p in ipairs(previewed) do                 -- no reply yet, or not in the served cells yet (30 s at most)
            if (p.n == 0 or p.n > done) and now - (p.at or 0) < 30 then
                for _, q in ipairs(p.parts) do waiting[q.id] = true end
            end
        end
        for id in pairs(moved) do
            if not want[id] and not waiting[id] then resteep.prop.keep(id); moved[id] = nil end
        end
    end
    return LV.on or next(want) ~= nil
end

local function live_end(put_back)
    if LV.on and put_back then for _, q in ipairs(LV.parts) do live_set(q.id, q.orig) end end
    LV.on = false
end

local K_EXISTING, K_COPY, K_PLACE = 0, 1, 2
local T_NONE, T_MOVE, T_ROTATE, T_SCALE = 0, 1, 2, 3
local M = {tool = T_NONE}               -- the running tool

-- what the target is made of in the game: {ids}, whether a group, a key naming it; or nil and why not
local function live_parts(n)
    local ix = cur_ix()
    if n.added then
        if n.model then return nil, "a model" end
        local id = add_id(map_name(), n.n)
        if not id then return nil, "the added object is not in the world yet" end
        return {id}, false, "a" .. n.n
    end
    if not n.i then return nil, "not in the index" end
    local id = ix.id[n.i]
    if ix.group[n.i] then
        local mem = ix.members[n.i]
        if not mem then return nil, "a group without members in the index" end
        return mem, true, "i" .. id
    end
    return {id}, false, "i" .. id
end

local function live_begin(m)
    local n = m.target
    local ids, group, key = nil, false, ""
    if m.kind == K_EXISTING then ids, group, key = live_parts(n) end
    if LV.on and not (ids and key == LV.key) then live_end(true) end
    if LV.on then                                        -- another tool on the same object: from where it was
        for _, q in ipairs(LV.parts) do live_set(q.id, q.orig); q.now = q.orig end
        return
    end
    LV.why = ""
    if m.kind ~= K_EXISTING then return end              -- a copy or a new prop: not in the world yet
    if not ids then LV.why = GONE .. " (" .. tostring(group) .. ")"; return end
    local parts = {}
    for k, id in ipairs(ids) do
        local found, why = resteep.prop.find(id)
        local cur = found and live_current(id)
        if not cur then LV.why = GONE .. " (" .. tostring(why or "not loaded") .. ")"; return end
        local dx, dy, dz = cur[13] - m.start[1], cur[14] - m.start[2], cur[15] - m.start[3]
        if dx * dx + dy * dy + dz * dz > (group and 300 or 50) ^ 2 then   -- elsewhere: another map, a stale cell
            LV.why = GONE .. " (the loaded object is elsewhere)"
            return
        end
        parts[k] = {id = id, orig = cur, now = cur}
    end
    LV.on, LV.key, LV.parts, LV.group, LV.gen, LV.pivot = true, key, parts, group, live_gen(), v3(m.start)
    LV.yaw = n.i and cur_ix().yaw[n.i] or 0
end

-- the tool's result on one object's matrix (not a group's member), as the edit tool_apply sends will place it
local function tool_matrix(m, o)
    if m.tool == T_MOVE then
        return P.moved(o, {m.start[1] + m.delta[1], m.start[2] + m.delta[2], m.start[3] + m.delta[3]})
    elseif m.tool == T_ROTATE then
        local axis = m.axis < 0 and 3 or m.axis
        local a = {0, 0, 0}
        a[axis] = 1
        if m.own then a = P.own_axis(o, axis) end
        if not a then return o end
        return P.turned(o, a, m.deg)
    end
    return P.scaled(o, m.factor)
end

-- the tool's result on a part's matrix, as the edit tool_apply sends will place it
local function live_matrix(m, o)
    if LV.group then                                     -- a member: the group's delta about the group's origin
        if m.tool == T_MOVE then return P.shifted(o, m.delta) end
        if m.tool == T_ROTATE then
            local axis = m.axis < 0 and 3 or m.axis
            local a = {0, 0, 0}
            a[axis] = 1
            if m.own then a = P.yawed_axis(LV.yaw, axis) end
            return P.turned_about(o, LV.pivot, a, m.deg)
        end
        return P.scaled_about(o, LV.pivot, m.factor)
    end
    return tool_matrix(m, o)
end

local function live_follow(m)
    if not LV.on or live_gen() ~= LV.gen then return end     -- a reload: the tool ends (edit_frame)
    for _, q in ipairs(LV.parts) do
        local t = live_matrix(m, q.orig)
        if P.valid(t) and not P.close(t, q.now, 1e-5) then
            if not live_set(q.id, t) then
                LV.why = GONE .. " (stopped: the overlay refused the move)"
                LV.on = false
                return
            end
            q.now = t
        end
    end
end

-- the edit tool_apply is about to send: the object stays where the preview left it; the reply may still put it back
local function live_sent()
    if not LV.on then return nil end
    local p = {parts = {}, token = next_token, n = 0, at = resteep.time()}
    for k, q in ipairs(LV.parts) do p.parts[k] = {id = q.id, before = q.orig, after = q.now} end
    next_token = next_token + 1
    if #previewed >= 64 then table.remove(previewed, 1) end
    previewed[#previewed + 1] = p
    LV.on = false
    return p.token
end

-- the server's answers: an edit refused, or (the list changed) edits gone (undone, cleared): their objects go back
-- where they were before the preview, newest first, as long as they still stand where the preview left them
local function live_net(list_changed)
    local back = {}
    for _, r in ipairs(sent) do
        for i, p in ipairs(previewed) do
            if p.token == r.token then
                if r.ok then p.n = r.n else back[#back + 1] = p; table.remove(previewed, i) end
                break
            end
        end
    end
    sent = {}
    if list_changed then
        local have = {}
        for _, e in ipairs(S.edits) do if type(e) == "table" and e.n then have[e.n] = true end end
        for i = #previewed, 1, -1 do
            local p = previewed[i]
            if p.n > 0 and not have[p.n] then back[#back + 1] = p; table.remove(previewed, i) end
        end
    end
    if #back == 0 then return end
    table.sort(back, function(a, b) return a.token > b.token end)
    local to = {}
    for _, p in ipairs(back) do
        for _, q in ipairs(p.parts) do
            local lq
            if LV.on then for _, x in ipairs(LV.parts) do if x.id == q.id then lq = x end end end
            if lq then                                   -- a tool on it now: its start goes back
                if P.close(lq.orig, q.after, 1e-2) then lq.orig = q.before end
            else
                local t = to[q.id]
                if not t then
                    local cur = live_current(q.id)
                    if cur then t = {m = cur, changed = false}; to[q.id] = t end
                end
                if t and P.close(t.m, q.after, 1e-2) then t.m, t.changed = q.before, true end
            end
        end
    end
    for id, t in pairs(to) do if t.changed then live_set(id, t.m) end end
end

-- ---- instant adds: a stand-in until the add's cell brings the copy ---------------------------------------------
-- With the "instant_adds" setting (resteep.prop.spawn: not seen in the game yet, 2026-11-15) an add whose source is
-- loaded (a duplicate, a prop placed near its example) shows at once: the game copies the loaded source and puts the
-- copy where world.py apply will put the add's (the source's matrix moved to the edit's position, turned by its yaw,
-- scaled). The stand-in goes when the add's own copy is loaded (the helper's adds.tsv names its id; both stand at the
-- same place meanwhile), when the server refuses the add, when a later edit changes or removes it (the stand-in would
-- show the old place), when the add is undone, after two minutes (its cell not read again: live edits off), and with
-- the world. Asked for here, made in the frame (the game's thread).
local SI = {ask = {}, live = {}}        -- ask: {src, m, token}; live: {id, token, n, map, at}
local function instant_adds()
    local ok, v = pcall(resteep.config.get, "instant_adds")
    return ok and v == true
end

-- the matrix world.py apply gives an add of `src` (its loaded matrix now) at `to`, turned by yaw, scaled
local function standin_ask(src, to, yaw, scale, token)
    if not instant_adds() or not src or not resteep.prop.find(src) then return end
    local cur = live_current(src)
    if not cur then return end
    local m = P.moved(cur, to)
    if abs(yaw) > 1e-6 then m = P.turned(m, {0, 0, 1}, yaw) end
    if abs(scale - 1) > 1e-6 then m = P.scaled(m, scale) end
    if P.valid(m) then SI.ask[#SI.ask + 1] = {src = src, m = m, token = token} end
end

local function standin_drop(k, why)
    local s_ = table.remove(SI.live, k)
    resteep.prop.unspawn(s_.id)
    if why ~= "" then S.note = "instant add: " .. why end
end

-- each frame, before live_net reads the replies: make what was asked, then let go of what is no longer wanted
local function standin_tick(list_changed)
    for _, a in ipairs(SI.ask) do
        local id, why = resteep.prop.spawn(a.src, {matrix = a.m})
        if id then SI.live[#SI.live + 1] = {id = id, token = a.token, n = 0, map = map_name(), at = resteep.time()}
        else S.note = "instant add: " .. tostring(why) end
    end
    SI.ask = {}
    if #SI.live == 0 then return end
    for _, r in ipairs(sent) do
        for _, s_ in ipairs(SI.live) do
            if s_.token == r.token then s_.n = r.ok and floor(r.n) or -1 end
        end
    end
    local touched = {}                                   -- adds that later edits change or remove
    if list_changed then
        for _, e in ipairs(S.edits) do
            if type(e) == "table" and type(e.n) == "number" then
                touched[e.n] = touched[e.n] or false
                if type(e.of) == "number" then touched[e.of] = true end
            end
        end
    end
    local now = resteep.time()
    for k = #SI.live, 1, -1 do
        local s_ = SI.live[k]
        local real = s_.n > 0 and add_id(s_.map, s_.n)
        if s_.n < 0 then standin_drop(k, "the server refused the add")
        elseif s_.map ~= map_name() or now - s_.at > 120 then standin_drop(k, "")
        elseif list_changed and s_.n > 0 and (touched[s_.n] == nil or touched[s_.n]) then standin_drop(k, "")
        elseif real and resteep.prop.find(real) then standin_drop(k, "") end
    end
end

-- ---- the free camera: flies anywhere while the rider stays (resteep.camera.set, input.capture, world.freeze) -------
-- Navigation as in Blender's viewport: middle mouse orbits about the selection (or a point ahead), Shift + middle
-- pans, the wheel zooms; the right mouse button held looks around and flies (WASD, Q/E down/up, wheel: speed). Only
-- the picture moves: the world still streams around the rider (~700 m). The field of view stays the game's (held
-- still, the engine's pause camera has its own and a value we set does not stick there): rays and boxes use the one
-- the picture was drawn with.
local FC = {on = false, pos = {0, 0, 0}, yaw = 0, pitch = 0, fov = 60, aspect = 0, speed = 15, freeze = true,
            let_run = false, held_fov = 0, drag = -1, frozen = false}

local function fc_axes()
    local cp = cos(rad(FC.pitch))
    local f = {cp * cos(rad(FC.yaw)), cp * sin(rad(FC.yaw)), sin(rad(FC.pitch))}
    local r = {sin(rad(FC.yaw)), -cos(rad(FC.yaw)), 0}       -- fwd x Z, flat
    return f, r, cross(r, f)
end

local function fc_start()
    local c = resteep.camera()
    if not c then return false end
    FC.pos = {c.x, c.y, c.z}
    FC.yaw = deg(atan(c.forward.y, c.forward.x))
    FC.pitch = deg(asin(clamp(c.forward.z, -1, 1)))
    FC.fov = (c.fov > 5 and c.fov < 150) and c.fov or 60
    FC.on, FC.drag, FC.held_fov = true, -1, 0
    resteep.log(fmt("free camera on at (%.1f, %.1f, %.1f), fov %.0f", FC.pos[1], FC.pos[2], FC.pos[3], FC.fov))
    return true
end

local function fc_stop()
    if FC.on then resteep.log("free camera off") end
    FC.on = false
    if FC.frozen then resteep.world.freeze(false); FC.frozen = false end
    resteep.camera.release()
end

local function fc_update(input, pivot, p, dt)
    if p.clicks.right > 0 then FC.drag = input and 1 or -1 end   -- a drag counts when it started over the world
    if p.clicks.middle > 0 then FC.drag = input and 2 or -1 end
    if FC.drag == 1 and not p.right then FC.drag = -1 end
    if FC.drag == 2 and not p.middle then FC.drag = -1 end
    if FC.drag > 0 then resteep.input.capture(true) else resteep.input.capture(true, "pointer") end
    local held = FC.freeze and not FC.let_run
    if held ~= FC.frozen then resteep.world.freeze(held); FC.frozen = held end
    local dx, dy = 0, 0
    if FC.drag > 0 then dx, dy = resteep.input.mouse() end
    local f, r, u = fc_axes()
    local at = pivot or vadd(FC.pos, f, 15)
    local dist = max(1, vlen(vsub(at, FC.pos)))
    local shift, ctrl = resteep.held("SHIFT"), resteep.held("CTRL")
    if FC.drag == 1 then
        FC.yaw = FC.yaw - dx * 0.15
        FC.pitch = clamp(FC.pitch - dy * 0.15, -89, 89)
        if p.wheel ~= 0 then FC.speed = clamp(FC.speed * 1.25 ^ p.wheel, 1, 400) end
    elseif FC.drag == 2 and shift then                   -- pan: the view slides
        local k = dist * 0.0015
        FC.pos = vadd(vadd(FC.pos, r, -dx * k), u, dy * k)
    elseif FC.drag == 2 then                             -- orbit about the pivot
        FC.yaw = FC.yaw - dx * 0.3
        FC.pitch = clamp(FC.pitch - dy * 0.3, -89, 89)
        local f2 = fc_axes()
        FC.pos = vadd(at, f2, -dist)
    elseif input and p.wheel ~= 0 then                   -- zoom: toward the pivot / the view
        FC.pos = vadd(FC.pos, f, min(dist * 0.15 * p.wheel, dist - 0.5))
    end
    FC.yaw = (FC.yaw + 540) % 360 - 180
    f, r = fc_axes()
    if FC.drag == 1 then                                 -- fly while looking (Blender's fly mode)
        local v = FC.speed * min(dt, 0.1) * (shift and 4 or 1) * (ctrl and 0.25 or 1)
        if resteep.held("W") then FC.pos = vadd(FC.pos, f, v) end
        if resteep.held("S") then FC.pos = vadd(FC.pos, f, -v) end
        if resteep.held("D") then FC.pos = vadd(FC.pos, r, v) end
        if resteep.held("A") then FC.pos = vadd(FC.pos, r, -v) end
        if resteep.held("E") then FC.pos = vadd(FC.pos, {0, 0, 1}, v) end
        if resteep.held("Q") then FC.pos = vadd(FC.pos, {0, 0, 1}, -v) end
    end
    f, r, u = fc_axes()
    local fov = FC.freeze and FC.let_run and FC.held_fov > 0 and FC.held_fov or nil   -- while let run: the held one
    resteep.camera.set{x = FC.pos[1], y = FC.pos[2], z = FC.pos[3], forward = vtab(f), up = vtab(u), fov = fov}
    local seen = resteep.camera()
    if seen and seen.fov > 5 and seen.fov < 150 then
        FC.fov, FC.aspect = seen.fov, seen.aspect
        if held or FC.held_fov == 0 then FC.held_fov = seen.fov end
    end
    -- this frame's view for rays and boxes
    FC.f, FC.r, FC.u = f, r, u
    FC.t = tan(rad(FC.fov) * 0.5)
    FC.asp = FC.aspect > 0.2 and FC.aspect or (p.h > 0 and p.w / p.h or 16 / 9)
end

local function fc_frame(center, radius)
    local f = fc_axes()
    FC.pos = vadd(center, f, -max(3, radius * 2.5))
end

-- the picture's ray through a point of the window (fractions), and a world point's place in it (nil: behind)
local function fc_ray(px, py)
    local nx, ny = 2 * px - 1, 1 - 2 * py
    local d = vadd(vadd(FC.f, FC.r, nx * FC.t * FC.asp), FC.u, ny * FC.t)
    local l = vlen(d)
    return FC.pos, {d[1] / l, d[2] / l, d[3] / l}
end
local function fc_project(q)
    local v = vsub(q, FC.pos)
    local depth = dot(v, FC.f)
    if depth < 0.1 then return nil end
    return (dot(v, FC.r) / (depth * FC.t * FC.asp) + 1) * 0.5, (1 - dot(v, FC.u) / (depth * FC.t)) * 0.5
end

-- ---- drawing over the world ----------------------------------------------------------------------------------------
-- a mod draws at most 512 things a frame: the lines here are counted (the frame handler starts at 0) and stop short
-- of it, room for the tool's header and pointer lines
local DRAW_CAP = 480
local drawn = 0
local function line(ax, ay, bx, by, color, thick)
    if drawn >= DRAW_CAP then return end
    drawn = drawn + 1
    resteep.line(ax, ay, bx, by, color, thick)
end
-- world point -> screen: the free camera's picture, else the game's camera (nil: behind it)
local function project3(x, y, z)
    if not (FC.on and FC.f) then return resteep.project(x, y, z) end
    local p, f, r, u = FC.pos, FC.f, FC.r, FC.u
    x, y, z = x - p[1], y - p[2], z - p[3]
    local depth = x * f[1] + y * f[2] + z * f[3]
    if depth < 0.1 then return nil end
    return ((x * r[1] + y * r[2] + z * r[3]) / (depth * FC.t * FC.asp) + 1) * 0.5,
        (1 - (x * u[1] + y * u[2] + z * u[3]) / (depth * FC.t)) * 0.5
end
local EDGES = {{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
local function corners_of(b)
    local c = {}
    for k = 0, 7 do
        c[k] = {(k & 1) ~= 0 and b.hi[1] or b.lo[1], (k & 2) ~= 0 and b.hi[2] or b.lo[2], (k & 4) ~= 0 and b.hi[3] or b.lo[3]}
    end
    return c
end
local function draw_corners(c, color, thick)
    local sx, sy = {}, {}
    for k = 0, 7 do sx[k], sy[k] = project3(c[k][1], c[k][2], c[k][3]) end
    for _, e in ipairs(EDGES) do
        local a, b = e[1], e[2]
        if sx[a] and sx[b] then line(sx[a], sy[a], sx[b], sy[b], color, thick) end
    end
end
local function draw_box(b, color, thick) draw_corners(corners_of(b), color, thick) end
-- a line through the world (the far end pulled in until both ends are in front of the camera)
local function draw_line3(a, b, color, thick)
    for _ = 1, 6 do
        local ax, ay = fc_project(a)
        local bx, by = fc_project(b)
        if ax and bx then line(ax, ay, bx, by, color, thick); return end
        local m = {(a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2}
        if not ax then a = m else b = m end
    end
end

-- ---- outlines: each object drawn as its wireframe, as it stands ----------------------------------------------------
-- outlines/<Map>/<prop>.tsv (tools/forge/outline.py, written with the index): a header with the rotation of the prop's
-- example (rows 1-3: an add copies that entity), then one line per edge, x1 y1 z1 x2 y2 z2, in the prop's own frame,
-- longest first. An object's outline goes where its matrix puts it (matrix_of): the loaded entity's own (tilt
-- included) while it stands where the edits put it, else the index's turn and scale (no tilt); a running tool's
-- result on that matrix as the live preview's. Groups (their members are not in the index), content mods' models and
-- props without an outline show their box. Read once per prop; false = none (an older outline v1 too: turned).
local OUTLINES = {}
local LIMIT_SEL, LIMIT_HOVER, LIMIT_TOOL = 300, 150, 300      -- lines per object (outlines have at most 300)
local function parse_outline(text)
    local _, _, ver, rest = find(text, "^# outline v(%d+) ([^\r\n]*)")
    if ver ~= "2" then return false end
    local w = {}
    for v in rest:gmatch("%S+") do w[#w + 1] = v end
    if #w < 12 then return false end
    local rot = {}
    for k = 1, 9 do rot[k] = tonumber(w[#w - 9 + k]) or 0 end
    local t = {}
    for line_ in text:gmatch("[^\r\n]+") do
        if line_:byte(1) ~= 35 then                     -- "#": the header
            for v in line_:gmatch("%S+") do t[#t + 1] = tonumber(v) or 0 end
        end
    end
    if #t < 6 then return false end
    return {e = t, rot = rot}
end
local function outline_of(prop)
    local ix = cur_ix()
    if not ix or not prop or prop == "" then return nil end
    local key = ix.map .. "/" .. prop
    local o = OUTLINES[key]
    if o == nil then
        local text = resteep.data.read("outlines/" .. key .. ".tsv")
        o = text and parse_outline(text) or false
        OUTLINES[key] = o
    end
    return o or nil
end

-- an object turned `yaw` degrees about Z and scaled about its origin at `pos` (the index's, without tilt)
local function yaw_matrix(yaw, scale, pos)
    local c, s = cos(rad(yaw)) * scale, sin(rad(yaw)) * scale
    return {c, s, 0, 0, -s, c, 0, 0, 0, 0, scale, 0, pos[1], pos[2], pos[3], 1}
end
-- whether a loaded matrix stands where the edits put the object (its cell may not be read again yet): the place
-- (the height loosely: "ground" is the terrain's), its scale, its turn about Z (unless an edit tilted it)
local function stands_as(m, pos, yaw, scale, tilted)
    if not m or (m[13] - pos[1]) ^ 2 + (m[14] - pos[2]) ^ 2 > 1 or abs(m[15] - pos[3]) > 30 then return false end
    local sc = (vlen({m[1], m[2], m[3]}) + vlen({m[5], m[6], m[7]}) + vlen({m[9], m[10], m[11]})) / 3
    if abs(sc - scale) > 0.03 * max(scale, 0.01) then return false end
    if tilted then return true end
    local d = deg(atan(m[2], m[1])) - yaw
    return abs(d - 360 * floor(d / 360 + 0.5)) < 2
end
-- the loaded entity's matrix if it stands as the edits say, else the index's turn and scale
local function pick_matrix(loaded, pos, yaw, scale, tilted)
    if stands_as(loaded, pos, yaw, scale, tilted) then return loaded end
    return yaw_matrix(yaw, scale, pos)
end

-- the loaded entities' matrices (resteep.prop.get, or what the live preview set), asked again twice a second; the
-- frame handler empties it when the edits change, a tool's end too
local MATS, MATS_N = {}, 0
local function loaded_matrix(key, id)
    local now = resteep.time()
    local c = MATS[key]
    if not c or now - c.at > 0.5 then
        if not c then
            if MATS_N >= 200 then MATS, MATS_N = {}, 0 end
            MATS_N = MATS_N + 1
        end
        c = {at = now, m = id and live_current(id) or false}
        MATS[key] = c
    end
    return c.m or nil
end
local function mats_reset() MATS, MATS_N = {}, 0 end

-- the matrix object `n` (shipped_row / added_row) stands with as the edits leave it; nil for a group or a model
local function matrix_of(n)
    local ix = cur_ix()
    local i = n.i
    if not ix or n.model or not i or ix.group[i] then return nil end
    if not n.added then
        local ch = W.changes[ix.key[i]]
        return pick_matrix(loaded_matrix(n.key, ix.id[i]), n.pos, n.yaw, n.scale, ch and ch.tilted)
    end
    -- an added copy: its own once loaded, else its source's moved, turned and scaled as world.py apply copies it
    local a = W.added[n.n]
    local yaw, scale = ix.yaw[i] + n.yaw, ix.scale[i] * n.scale
    local id = add_id(map_name(), n.n)
    local own = id and loaded_matrix(n.key, id)
    if stands_as(own, n.pos, yaw, scale, a and a.tilted) then return own end
    local src = loaded_matrix("o:" .. ix.key[i], ix.id[i])
    if stands_as(src, {ix.x[i], ix.y[i], ix.z[i]}, ix.yaw[i], ix.scale[i], false) then
        local m = P.moved(src, n.pos)
        if abs(n.yaw) > 1e-6 then m = P.turned(m, {0, 0, 1}, n.yaw) end
        if abs(n.scale - 1) > 1e-6 then m = P.scaled(m, n.scale) end
        return m
    end
    return yaw_matrix(yaw, scale, n.pos)
end
local function outline_for(n)
    return n.i and not n.model and outline_of(cur_ix().prop[n.i]) or nil
end

-- outline `o` where matrix `m` puts it (16 numbers: rows 1-3 the axes, row 4 the origin): at most `limit` lines, the
-- longest first, those with an end behind the camera left out
local function draw_outline(o, m, color, thick, limit)
    local e = o.e
    local a1, a2, a3, b1, b2, b3 = m[1], m[2], m[3], m[5], m[6], m[7]
    local c1, c2, c3, t1, t2, t3 = m[9], m[10], m[11], m[13], m[14], m[15]
    limit = min(limit, DRAW_CAP - drawn)
    local n = 0
    for k = 1, #e - 5, 6 do
        if n >= limit then break end
        local x, y, z = e[k], e[k + 1], e[k + 2]
        local ax, ay = project3(x * a1 + y * b1 + z * c1 + t1, x * a2 + y * b2 + z * c2 + t2,
                                x * a3 + y * b3 + z * c3 + t3)
        if ax then
            x, y, z = e[k + 3], e[k + 4], e[k + 5]
            local bx, by = project3(x * a1 + y * b1 + z * c1 + t1, x * a2 + y * b2 + z * c2 + t2,
                                    x * a3 + y * b3 + z * c3 + t3)
            if bx then
                line(ax, ay, bx, by, color, thick)
                n = n + 1
            end
        end
    end
end
-- the outline `o` at matrix `m` when both are there, else the box (8 corners, corners_of)
local function draw_as(o, m, corners, color, thick, box_thick, limit)
    if o and m then draw_outline(o, m, color, thick, limit) else draw_corners(corners, color, box_thick) end
end
-- object `n` as it stands: its outline, else its box
local function draw_object(n, color, thick, box_thick, limit)
    local o = outline_for(n)
    draw_as(o, o and matrix_of(n), corners_of(n.box), color, thick, box_thick, limit)
end

-- the ghost of an add: the example's rotation, turned `yaw` degrees about Z and scaled by `scale` about its origin
-- at `pos` (as world.py apply copies it)
local function ghost_matrix(o, pos, yaw, scale)
    local r = o.rot
    local m = {r[1], r[2], r[3], 0, r[4], r[5], r[6], 0, r[7], r[8], r[9], 0, pos[1], pos[2], pos[3], 1}
    if abs(yaw) > 1e-6 then m = P.turned(m, {0, 0, 1}, yaw) end
    if abs(scale - 1) > 1e-6 then m = P.scaled(m, scale) end
    return m
end
-- draws `prop`'s ghost; false when the prop has no outline (draw its box instead)
local function draw_ghost(prop, pos, yaw, scale, color, thick)
    local o = outline_of(prop)
    if not o then return false end
    draw_outline(o, ghost_matrix(o, pos, yaw, scale), color, thick, LIMIT_TOOL)
    return true
end

-- the ray's entry into the box lo (x0, y0, z0) .. hi (x1, y1, z1) (slab test); nil when it misses or starts inside
-- (big things around the camera)
local function slab(lo, hi, o, d, t0, t1)            -- one axis: the ray's interval narrowed, nil = missed
    if abs(d) < 1e-9 then
        if o < lo or o > hi then return nil end
        return t0, t1
    end
    local a, c = (lo - o) / d, (hi - o) / d
    if a > c then a, c = c, a end
    if a > t0 then t0 = a end
    if c < t1 then t1 = c end
    if t1 < t0 then return nil end
    return t0, t1
end
local function hit_box(x0, y0, z0, x1, y1, z1, o, d)
    local t0, t1 = slab(x0, x1, o[1], d[1], -1e30, 1e30)
    if t0 then t0, t1 = slab(y0, y1, o[2], d[2], t0, t1) end
    if t0 then t0, t1 = slab(z0, z1, o[3], d[3], t0, t1) end
    if not t0 or t0 <= 0 then return nil end
    return t0
end

-- ---- the edit mode's tools: G move, R rotate, S scale, Shift+D duplicate, Shift+A place --------------------------
local AXIS_COLORS = {"#FFF05050", "#FF6EDC5A", "#FF5A96FF"}
local AXIS_NAMES = {"X", "Y", "Z"}
local CYAN, YELLOW, WHITE = "#FF50DCFF", "#FFFFD23C", "#A0FFFFFF"

-- the object's axis k (1..3): the map's, or (own) its own turned by its yaw (a tilt is not known here)
local function axis_vec(n, k, own)
    local w = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
    if not own or k == 3 then return w[k] end
    local yaw = (n.added and n.i and not n.model) and cur_ix().yaw[n.i] + n.yaw or n.yaw   -- a copy: its source's too
    local c, s = cos(rad(yaw)), sin(rad(yaw))
    return k == 1 and {c, s, 0} or {-s, c, 0}
end

-- p turned about the unit axis a through o by d degrees
local function turn_about(p, o, a, d)
    local t = rad(d)
    local c, s = cos(t), sin(t)
    local v = vsub(p, o)
    local x, dd = cross(a, v), dot(a, v)
    return {o[1] + v[1] * c + x[1] * s + a[1] * dd * (1 - c), o[2] + v[2] * c + x[2] * s + a[2] * dd * (1 - c),
            o[3] + v[3] * c + x[3] * s + a[3] * dd * (1 - c)}
end

local function ray_plane(o, d, p0, nrm)
    local den = dot(d, nrm)
    if abs(den) < 1e-5 then return nil end
    local t = dot(vsub(p0, o), nrm) / den
    if t <= 0 or t > 5000 then return nil end
    return vadd(o, d, t)
end

-- the point of the line (p0, a) closest to the ray: its parameter along a
local function ray_line(o, d, p0, a)
    local w = vsub(o, p0)
    local b, dd, aa = dot(a, d), dot(d, d), dot(a, a)
    local den = aa * dd - b * b
    if abs(den) < 1e-6 then return nil end
    local t = (dot(a, w) * dd - b * dot(d, w)) / den
    return t == t and t or nil
end

local function tool_begin(tool, kind, n, p)
    M = {tool = tool, kind = kind, target = n, start = v3(n.pos), mouse0 = {p.x, p.y}, axis = -1, own = false,
         plane = false, typed = "", angle_prev = nil, angle = 0, delta = {0, 0, 0}, deg = 0, factor = 1}
    S.note = ""
    live_begin(M)
    if kind ~= K_PLACE then                              -- its outline follows the tool from where it stands
        mats_reset()
        M.outline = outline_for(n)
        M.base = M.outline and (LV.on and not LV.group and LV.parts[1].orig or matrix_of(n))
    end
end

local function can_copy(n)
    return n.model ~= nil or (n.i ~= nil and (n.added or not cur_ix().group[n.i]))
end

local function place_prop(p)
    local pr = S.prop
    if not pr then S.note = "choose a prop in the panel's list first"; return end
    local ix = cur_ix()
    local i = pr.example
    local at = vadd(FC.pos, FC.f, 12)                    -- starts 12 m ahead, follows the pointer from there
    local b = box_of_index(ix, i, S.add_yaw, S.add_scale, at)
    tool_begin(T_MOVE, K_PLACE, {i = i, name = pr.name, pos = at, yaw = S.add_yaw, scale = S.add_scale, box = b}, p)
end

-- the tool's result as one edit (an object the live preview moved stays there: live_sent)
local function tool_apply()
    local m, n = M, M.target
    local to = {m.start[1] + m.delta[1], m.start[2] + m.delta[2], m.start[3] + m.delta[3]}
    local ix = cur_ix()
    if m.tool == T_MOVE and m.kind == K_EXISTING then
        if abs(m.delta[1]) + abs(m.delta[2]) + abs(m.delta[3]) > 1e-4 then
            edit_send(n, "move", "pos", jpos(to), nil, live_sent())
            S.sel_pos = to
        end
    elseif m.tool == T_MOVE then                         -- a copy, or a new prop: an add
        if target_cell(ix, to[1], to[2]) < 0 then S.note = "no cell of the map there"; return end
        local j = {map = map_name(), op = "add", pos = jpos(to)}
        local token
        if n.model then
            j.model, j.name, j.yaw, j.scale = n.model, n.model, r3(n.yaw), r3(n.scale)
        else
            local a = n.added and W.added[n.n]
            local shipped = m.kind == K_PLACE or not n.added
            j.src = (shipped or not a) and {layer = ix.layer[n.i], cell = ix.cell[n.i], id = hex(ix.id[n.i])}
                or {layer = a.src_layer, cell = a.src_cell, id = a.src_id}
            j.name = ix.prop[n.i] ~= "" and ix.prop[n.i] or n.name
            j.yaw = r3(m.kind == K_PLACE and S.add_yaw or n.added and n.yaw or n.yaw - ix.yaw[n.i])
            j.scale = r3(m.kind == K_PLACE and S.add_scale or n.added and n.scale or n.scale / max(0.01, ix.scale[n.i]))
            token = next_token                           -- a stand-in now (instant adds): the loaded object copied
            next_token = next_token + 1
            if m.kind == K_PLACE then standin_ask(ix.id[n.i], to, S.add_yaw, S.add_scale, token)
            elseif n.added then standin_ask(add_id(map_name(), n.n), to, 0, 1, token)   -- the copy as it stands
            else standin_ask(ix.id[n.i], to, 0, 1, token) end
        end
        request("POST", "edits", j, "add", token)
        S.select_newest = true
    elseif m.tool == T_ROTATE and abs(m.deg) > 1e-3 then
        local axis = m.axis < 0 and 3 or m.axis
        if axis == 3 and not m.own then
            edit_send(n, "turn", "deg", r3(m.deg), nil, live_sent())
        else
            edit_send(n, "rotate", "deg", r3(m.deg), {axis = ({"x", "y", "z"})[axis], ["local"] = m.own}, live_sent())
        end
    elseif m.tool == T_SCALE and abs(m.factor - 1) > 1e-4 then
        local after = n.scale * m.factor
        if after < 0.05 or after > 20 then S.note = "scale out of range (0.05 .. 20)"; return end
        edit_send(n, "scale", "factor", r3(m.factor), nil, live_sent())
    end
end

local DIGITS = {PERIOD = ".", COMMA = ".", DECIMAL = "."}
for k = 0, 9 do DIGITS[tostring(k)] = tostring(k); DIGITS["NUMPAD" .. k] = tostring(k) end

local function typed_value()
    local t = M.typed
    if t == "" or t == "-" or t == "." then return nil end
    return tonumber(t)
end

-- the keys and clicks of a running tool: axis locks, typing, confirm, cancel; false when it ended
local function tool_keys(p)
    local m = M
    for key, tool in pairs({G = T_MOVE, R = T_ROTATE, S = T_SCALE}) do   -- another tool on the same object
        if pressed[key] and tool ~= m.tool and m.kind == K_EXISTING then
            tool_begin(tool, K_EXISTING, m.target, p)
            return true
        end
    end
    for k, key in ipairs(AXIS_NAMES) do
        if pressed[key] then
            if resteep.held("SHIFT") then m.axis, m.plane, m.own = k, true, false
            elseif m.axis ~= k or m.plane then m.axis, m.plane, m.own = k, false, false
            elseif not m.own then m.own = true                         -- again: its own axis; once more: free
            else m.axis, m.own = -1, false end
        end
    end
    for key, c in pairs(DIGITS) do
        if pressed[key] and #m.typed < 12 then m.typed = m.typed .. c end
    end
    if pressed.MINUS or pressed.SUBTRACT then
        m.typed = sub(m.typed, 1, 1) == "-" and sub(m.typed, 2) or "-" .. m.typed
    end
    if pressed.BACKSPACE and #m.typed > 0 then m.typed = sub(m.typed, 1, -2) end
    if pressed.ESCAPE or p.clicks.right > 0 then
        live_end(true)                                   -- cancelled: the object back where it was
        m.tool = T_NONE
        mats_reset()
        return false
    end
    if pressed.ENTER or pressed.SPACE or p.clicks.left > 0 then
        tool_apply()
        live_end(true)                                   -- still on: nothing was sent (no change, out of range)
        m.tool = T_NONE
        mats_reset()
        return false
    end
    return true
end

-- the running tool's result from the pointer (or the typed number), and its picture; the header text
local function tool_update(p)
    local m, n = M, M.target
    local p0 = m.start
    local o, d = fc_ray(p.x, p.y)
    local o0, d0 = fc_ray(m.mouse0[1], m.mouse0[2])
    local typed = typed_value()
    local snap = resteep.held("CTRL")
    local lock = m.axis < 0 and "" or ((m.plane and " (not " or " along ") .. AXIS_NAMES[m.axis]
        .. (m.own and ", own axis" or "") .. (m.plane and ")" or ""))
    if m.axis > 0 then                                   -- the lock's axis (both others for a plane)
        for k = 1, 3 do
            if (m.plane and k ~= m.axis) or (not m.plane and k == m.axis) then
                local a = axis_vec(n, k, m.own)
                draw_line3(vadd(p0, a, -500), vadd(p0, a, 500), AXIS_COLORS[k], 1.5)
            end
        end
    end
    local head
    local px, py = p.x * p.w, p.y * p.h
    if m.tool == T_MOVE then
        local dl = {0, 0, 0}
        if typed then
            local a = axis_vec(n, m.axis < 0 and 1 or m.axis, m.own)
            dl = {a[1] * typed, a[2] * typed, a[3] * typed}
        elseif m.axis > 0 and not m.plane then
            local a = axis_vec(n, m.axis, m.own)
            local t, t0 = ray_line(o, d, p0, a), ray_line(o0, d0, p0, a)
            if t and t0 then
                local s = t - t0
                if snap then s = floor(s * 2 + 0.5) / 2 end
                dl = {a[1] * s, a[2] * s, a[3] * s}
            end
        else
            local nrm = m.axis > 0 and axis_vec(n, m.axis, m.own) or FC.f
            local h, h0 = ray_plane(o, d, p0, nrm), ray_plane(o0, d0, p0, nrm)
            if h and h0 then
                dl = vsub(h, h0)
                if snap then for i = 1, 3 do dl[i] = floor(dl[i] * 2 + 0.5) / 2 end end
            end
        end
        m.delta = dl
        if not (m.kind == K_PLACE and draw_ghost(n.name, vadd(n.pos, dl), n.yaw, n.scale, CYAN, 1.5)) then
            draw_as(m.outline, m.base and P.shifted(m.base, dl), corners_of({lo = vadd(n.box.lo, dl),
                    hi = vadd(n.box.hi, dl)}), CYAN, 1.5, 2.5, LIMIT_TOOL)
        end
        head = fmt("%s %s  D: %.2f  %.2f  %.2f m%s%s", m.kind == K_EXISTING and "Move" or m.kind == K_COPY and
                   "Duplicate" or "Place", n.name, dl[1], dl[2], dl[3], lock, typed and "  (typed)" or "")
    elseif m.tool == T_ROTATE then
        local axis = m.axis < 0 and 3 or m.axis
        local a = axis_vec(n, axis, m.own)
        local cx, cy = fc_project(p0)
        if typed then
            m.deg = typed
        elseif cx then
            cx, cy = cx * p.w, cy * p.h
            local ang = deg(atan(-(py - cy), px - cx))
            if not m.angle_prev then m.angle_prev = deg(atan(-(m.mouse0[2] * p.h - cy), m.mouse0[1] * p.w - cx)) end
            local step = ang - m.angle_prev
            step = step - 360 * floor(step / 360 + 0.5)
            m.angle = m.angle + step
            m.angle_prev = ang
            -- counter-clockwise on screen is a positive turn about an axis that points at the viewer
            local dg = dot(a, FC.f) > 0 and -m.angle or m.angle
            m.deg = snap and floor(dg / 5 + 0.5) * 5 or dg
            resteep.line(cx / p.w, cy / p.h, p.x, p.y, "#78FFFFFF", 1)
        end
        local c = corners_of(n.box)
        for k = 0, 7 do c[k] = turn_about(c[k], p0, a, m.deg) end
        draw_as(m.outline, m.base and tool_matrix(m, m.base), c, CYAN, 1.5, 2.5, LIMIT_TOOL)
        head = fmt("Rotate %s  %.1f deg about %s%s%s", n.name, m.deg, AXIS_NAMES[axis], m.own and " (own axis)" or "",
                   typed and "  (typed)" or "")
    else
        local cx, cy = fc_project(p0)
        if typed then
            m.factor = typed
        elseif cx then
            cx, cy = cx * p.w, cy * p.h
            local d1 = sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
            local dm = max(8, sqrt((m.mouse0[1] * p.w - cx) ^ 2 + (m.mouse0[2] * p.h - cy) ^ 2))
            m.factor = d1 / dm
            if snap then m.factor = max(0.1, floor(m.factor * 10 + 0.5) / 10) end
            resteep.line(cx / p.w, cy / p.h, p.x, p.y, "#78FFFFFF", 1)
        end
        local c = corners_of(n.box)
        for k = 0, 7 do c[k] = vadd(p0, vsub(c[k], p0), m.factor) end
        draw_as(m.outline, m.base and tool_matrix(m, m.base), c, CYAN, 1.5, 2.5, LIMIT_TOOL)
        head = fmt("Scale %s  x%.3f%s%s", n.name, m.factor,
                   m.axis > 0 and "  (scaling is uniform: the axis lock does nothing)" or "", typed and "  (typed)" or "")
    end
    live_follow(m)
    if m.typed ~= "" then head = head .. "   [" .. m.typed .. "]" end
    if LV.on then head = head .. "   (live)" end
    return head
end

-- ---- the panel's parts (also the free camera's window: the selection's exact position, turn, scale) --------------
local draw_selected

local function draw_position()
    if not S.have_pos then
        ui.text("player position unknown (not in a world yet)", "dim")
        return
    end
    ui.text(fmt("position  x %.1f  y %.1f  z %.1f%s", S.me[1], S.me[2], S.me[3],
                S.have_heading and fmt("   heading %.0f deg", deg(S.heading)) or ""))
    local ix = cur_ix()
    if not ix or not ix.grid then return end
    local c0 = grid_at(ix.grid, S.me[1], S.me[2], 0)
    local t, level = target_cell(ix, S.me[1], S.me[2])
    if c0 < 0 then
        ui.text("outside " .. map_name() .. "'s cells", "dim")
    else
        local _, x0, y0, size = grid_rect(ix.grid, c0)
        ui.text(fmt("cell %05d (x %.0f..%.0f, y %.0f..%.0f)%s", c0, x0, x0 + size, y0, y0 + size,
                    ix.cells0[c0] and "" or ": empty"))
        if t >= 0 and t ~= c0 then ui.text(fmt("added objects go into cell %05d (level %d)", t, level), "dim") end
    end
end

local function draw_add()
    local ix = cur_ix()
    ui.text("Experimental: copies may show visual artifacts. Moves, turns, scales and removes do not depend on "
            .. "them (WORLD_EDITOR_ADDS=0 leaves copies out).", "warn")
    S.filter = ui.input("##filter", S.filter, {hint = "filter, e.g. sapin, rock, kick", width = -1})
    S.favs_only = ui.checkbox("favourites only", S.favs_only)
    local f = S.filter:lower()
    local shown, labels, sel = {}, {}, 0
    for _, p in ipairs(ix.props) do
        if (not S.favs_only or p.fav) and (f == "" or find(p.lower, f, 1, true)) and #shown < 2000 then
            shown[#shown + 1] = p
            labels[#labels + 1] = p.label
            if p == S.prop then sel = #shown end
        end
    end
    local chosen, changed = ui.list("##props", labels, sel, {height = 7})
    if changed and shown[chosen] then S.prop = shown[chosen] end
    ui.text(fmt("%d of %d placeable props", #shown, #ix.props), "dim")
    S.ahead = ui.slider("metres in front", S.ahead, 0, 40, {format = "%.1f"})
    S.on_ground = ui.checkbox("on the ground", S.on_ground)
    ui.text(S.on_ground and "(the terrain under it + the height offset)" or "(your height + the offset)", "dim")
    S.dz = ui.slider("height offset", S.dz, -10, 10, {format = "%.1f m"})
    S.add_yaw = ui.slider("turn", S.add_yaw, -180, 180, {format = "%.0f deg"})
    S.add_scale = ui.slider("scale", S.add_scale, 0.25, 4, {format = "%.2f"})
    local at = ahead_of(S.ahead)
    local cell = target_cell(ix, at[1], at[2])
    local ok = S.have_pos and S.prop ~= nil and cell >= 0
    if ok then                                           -- the ghost (drawn by the frame handler while this shows)
        local z = at[3]
        if S.on_ground then
            local g = resteep.world.ground(at[1], at[2])
            if g then z = g + S.dz end
        end
        S.ghost = {prop = S.prop.name, pos = {at[1], at[2], z}, yaw = S.add_yaw, scale = S.add_scale,
                   t = resteep.time()}
    end
    S.ghost_has = S.prop ~= nil and outline_of(S.prop.name) ~= nil
    if ui.button("Add here", {disabled = not ok}) then
        local ex = S.prop.example
        local j = {map = map_name(), op = "add", name = S.prop.name,
                   src = {layer = ix.layer[ex], cell = ix.cell[ex], id = hex(ix.id[ex])},
                   pos = jpos(at), yaw = r3(S.add_yaw), scale = r3(S.add_scale)}
        if S.on_ground then j.ground = r3(S.dz) end        -- world.py apply puts it on the .tbf terrain
        local token = next_token                         -- a stand-in now, if its example is loaded (instant adds)
        next_token = next_token + 1
        standin_ask(ix.id[ex], S.ghost and S.ghost.pos or at, S.add_yaw, S.add_scale, token)
        request("POST", "edits", j, "add", token)
    end
    if S.prop and not S.ghost_has then ui.text("(no outline of this prop: its box shows where it goes)", "dim") end
    if not S.have_pos then ui.text("(no position)", "dim")
    elseif cell < 0 then ui.text("(no cell of " .. map_name() .. " there)", "dim")
    else
        ui.text(fmt("at (%.1f, %.1f, %.1f)%s", at[1], at[2], at[3],
                    S.have_heading and "" or ", north of you: ride a few metres to set the heading"), "dim")
    end
end

function draw_selected(s)
    local ix = cur_ix()
    ui.text(s.name .. (s.added and "  (added)" or ""))
    if not s.added and s.i then
        ui.text(fmt("%s, cell %05d%s", hex(ix.id[s.i]), ix.cell[s.i], ix.group[s.i] and ", group" or ""), "dim")
    end
    ui.text(fmt("at (%.2f, %.2f, %.2f), turned %.0f deg, scale %.2f", s.pos[1], s.pos[2], s.pos[3], s.yaw, s.scale))
    for k, axis in ipairs({"x##sel", "y##sel", "z##sel"}) do
        if k > 1 then ui.same_line() end
        S.sel_pos[k] = ui.number(axis, S.sel_pos[k], {format = "%.2f", width = 5})
    end
    if ui.button("Move") then edit_send(s, "move", "pos", jpos(S.sel_pos)) end
    ui.same_line()
    if ui.button("Onto the ground") then edit_send(s, "ground", "offset", 0) end   -- the terrain under it (End)
    if ui.button("to me", {disabled = not S.have_pos}) then S.sel_pos = v3(S.me) end
    ui.same_line()
    if ui.button("to in front", {disabled = not S.have_pos}) then S.sel_pos = ahead_of(S.ahead) end
    if not s.added and s.i and ix.grid then              -- shipped objects stay in their cell (streaming, culling)
        local _, x0, y0, size = grid_rect(ix.grid, ix.cell[s.i])
        local p = S.sel_pos
        if x0 and (p[1] < x0 - 8 or p[1] > x0 + size + 8 or p[2] < y0 - 8 or p[2] > y0 + size + 8) then
            ui.text(fmt("outside its cell (%.0f..%.0f, %.0f..%.0f): it may not show there; remove it and add a copy "
                        .. "instead", x0, x0 + size, y0, y0 + size), "warn")
        end
    end
    local function turn(d) edit_send(s, "turn", "deg", r3(d)) end
    local function scale(f)
        local after = s.scale * f
        if after >= 0.05 and after <= 20 then edit_send(s, "scale", "factor", r3(f)) end   -- world.py's sane range
    end
    for i, d in ipairs({-90, -15, 15, 90}) do
        if i > 1 then ui.same_line() end
        if ui.button(fmt("%+d", d), {small = true}) then turn(d) end
    end
    ui.same_line()
    S.turn = ui.number("##turn", S.turn, {format = "%.0f", width = 4})
    ui.same_line()
    if ui.button("Turn", {small = true}) then turn(clamp(S.turn, -360, 360)) end
    for i, f in ipairs({0.8, 1.25, 2}) do
        if i > 1 then ui.same_line() end
        if ui.button(fmt("x%g", f), {small = true}) then scale(f) end
    end
    ui.same_line()
    S.factor = ui.number("##factor", S.factor, {format = "%.2f", width = 4})
    ui.same_line()
    if ui.button("Scale", {small = true}) then scale(clamp(S.factor, 0.05, 20)) end
    if ui.button("Remove", {color = "#FF992626"}) then
        edit_send(s, "remove")
        S.sel = ""
    end
end

local function select_row(n)
    S.sel = n.key
    S.sel_pos = v3(n.pos)
end

local function draw_nearby()
    if not S.have_pos then ui.text("(no position)", "dim"); return end
    S.radius = ui.slider("radius", S.radius, 5, 300, {format = "%.0f m", width = 8})
    S.all_kinds = ui.checkbox("also cameras, anchors, FX", S.all_kinds)
    local rows = near("panel", S.me, floor(S.radius), S.all_kinds, 2, function(g) return nearest(g, S.me, 200) end)
    local cells, sel, chosen = {}, 0, nil
    local ix = cur_ix()
    for k = 1, #rows do
        local n = rows[k]
        cells[k] = {n.name, fmt("%.0f", n.dist), n.added and "added" or n.changed and "changed"
                    or (n.i and ix.group[n.i]) and "group" or ""}
        if n.key == S.sel then sel, chosen = k, n end
    end
    local k, changed = ui.list("near", cells, sel, {columns = {"Object", "m", ""}, height = 8})
    if changed and rows[k] then select_row(rows[k]); chosen = rows[k] end
    chosen = chosen or row_for_key(S.sel, S.me)        -- selected, but not among the nearest shown
    if chosen then draw_selected(chosen)
    else ui.text("select an object to move, turn, scale or remove it", "dim") end
end

-- the server's rules (mod.lua): what you may do; for admins the rules themselves and removing a player's edits
local function draw_rules()
    local r = S.rules
    if type(r) ~= "table" then return end
    local admin = type(r.you) == "table" and r.you.admin == true
    local mode = r.edit or "admins"
    if not admin then
        ui.text(mode == "everyone" and "This server lets players edit." or mode == "off" and
                "Editing is off on this server." or "Only the server's admins edit here.", "dim")
        return
    end
    ui.section("Server rules (admin)", function()
        if S.rules_seen ~= r then                        -- take the server's values when they change
            S.rules_seen = r
            S.r_mode = mode == "everyone" and 2 or mode == "off" and 3 or 1
            S.r_undo = r.undo_others ~= false
            S.r_shipped = r.shipped_objects ~= false
            S.r_adds = floor(tonumber(r.max_adds) or 0)
            S.r_edits = floor(tonumber(r.max_edits) or 0)
        end
        S.r_mode = ui.combo("who may edit", {"admins only", "everyone", "off"}, S.r_mode, {width = 8})
        S.r_undo = ui.checkbox("players may undo / change others' edits", S.r_undo)
        S.r_shipped = ui.checkbox("players may change the game's own objects", S.r_shipped)
        S.r_adds = ui.number("objects per player (0: any)", S.r_adds, {int = true, step = 1, width = 6})
        S.r_edits = ui.number("edits per player (0: any)", S.r_edits, {int = true, step = 1, width = 6})
        if ui.button("Apply rules") then
            request("POST", "rules", {edit = ({"admins", "everyone", "off"})[S.r_mode], undo_others = S.r_undo,
                                      shipped_objects = S.r_shipped, max_adds = max(0, S.r_adds),
                                      max_edits = max(0, S.r_edits)}, "rules")
        end
        local by, order = {}, {}                         -- whose edits there are on this map
        for _, e in ipairs(S.edits) do
            if type(e) == "table" and e.map == map_name() and type(e.by) == "string" then
                if not by[e.by] then by[e.by] = {name = type(e.by_name) == "string" and e.by_name or "?", n = 0}; order[#order + 1] = e.by end
                by[e.by].n = by[e.by].n + 1
            end
        end
        for _, who in ipairs(order) do
            ui.text(fmt("%s: %d edit(s)", by[who].name, by[who].n))
            ui.same_line()
            if ui.button("remove all of theirs##" .. who, {small = true}) then request("POST", "purge", {by = who}, "purge") end
        end
    end)
end

-- live edits (the overlay's, resteep.world.live): what the session helper has turned into cells, and whether the
-- game has read them yet
local function draw_live()
    local ls = resteep.world.live()
    local newest = 0
    for _, e in ipairs(S.edits) do if type(e) == "table" then newest = max(newest, e.n or 0) end end
    if not ls or not ls.hooked or not ls.helper then
        ui.text("Edits show from the next game start." .. (ls and ls.note ~= "" and " " .. ls.note or ""), "dim")
        return
    end
    if ls.edits < newest then
        ui.text(fmt("live: writing the cells of edit #%d... (the helper is at #%d)", floor(newest), ls.edits), "warn")
    else
        ui.text(fmt("live: %d cell(s) replaced. Loaded cells are read again at once; the others when they stream in.",
                    #ls.cells), "good")
    end
    if ls.note ~= "" then ui.text(ls.note, "dim") end
    if ls.reload ~= "" then ui.text(ls.reload, "dim") end
    if #ls.cells == 0 then return end
    ui.section("live cells", function()
        for _, c in ipairs(ls.cells) do
            ui.text(fmt("%s %s (%s): %s", c.map, c.name, c.mode == "same" and "same size" or "bigger: index redirected",
                        c.state))
        end
        if ls.io ~= "" then ui.text(ls.io, "dim") end
    end)
end

local function draw_edits()
    local count, mine = 0, {}
    for _, e in ipairs(S.edits) do
        if type(e) == "table" and e.map == map_name() then count = count + 1; mine[#mine + 1] = e end
    end
    ui.text(fmt("%d edit(s) of %s", count, map_name()))
    if ui.button("Refresh") then request("GET", "edits", nil, "refresh"); request("GET", "rules", nil, "rules") end
    ui.same_line()
    local last = last_edit()
    if ui.button("Undo last", {disabled = last == 0}) then request("POST", "undo", {map = map_name()}, "undo") end
    ui.same_line()
    if ui.button("Clear all...", {disabled = last == 0}) then S.clear_ask = not S.clear_ask end
    if S.clear_ask and last > 0 then
        ui.text(fmt("Remove all %d edits of %s?", count, map_name()), "warn")
        if ui.button("Yes, clear them") then request("POST", "clear", {map = map_name()}, "clear"); S.clear_ask = false end
        ui.same_line()
        if ui.button("No") then S.clear_ask = false end
    end
    ui.scroll("edits", 7, function()
        for k = #mine, max(1, #mine - MAX_EDITS_SHOWN + 1), -1 do
            local e = mine[k]
            local n = floor(e.n or 0)
            if ui.button("undo##" .. n, {small = true}) then request("POST", "undo", {n = n}, "undo") end
            ui.same_line()
            ui.text(describe(e))
        end
        if #mine > MAX_EDITS_SHOWN then ui.text(fmt("(and %d older)", #mine - MAX_EDITS_SHOWN), "dim") end
    end)
    draw_rules()
    draw_live()
end

-- ---- the edit mode: the free camera, objects picked and changed with Blender's keys --------------------------------
local function edit_start()
    local ix = cur_ix()
    if not ix or ix.error then S.note = "no index for this map"; return end
    if not fc_start() then S.note = "no camera (not in a world?)"; return end
    S.edit = true
    M = {tool = T_NONE}
    S.note = ""
    ui.menu(false)
end

local function edit_stop()
    live_end(true)
    S.edit = false
    M = {tool = T_NONE}
    fc_stop()
end

local function draw_tools(sel, p)
    ui.window("World editor: free camera", {x = 12, y = 12, alpha = 0.75}, function()
        FC.speed = ui.slider("##speed", FC.speed, 1, 400, {format = "%.0f m/s", log = true, width = 7})
        ui.same_line()
        FC.freeze = ui.checkbox("hold the world", FC.freeze)
        ui.same_line()
        if ui.button("Leave (Esc)") then edit_stop(); return end
        local away = sqrt((FC.pos[1] - S.me[1]) ^ 2 + (FC.pos[2] - S.me[2]) ^ 2)
        ui.text(fmt("%s (%.0f, %.0f, %.0f)", map_name(), FC.pos[1], FC.pos[2], FC.pos[3]), "dim")
        if S.have_pos and away > 600 then
            ui.text(fmt("%.0f m from the rider: the world streams around the rider, cells here may be missing and "
                        .. "edits show only when the rider comes", away), "warn")
        end
        ui.text(S.status, status_color())
        if S.note ~= "" then ui.text(S.note, "warn") end
        ui.separator()
        if M.tool ~= T_NONE then
            ui.text("X / Y / Z lock (again: own axis), Shift+axis: the other two, type a number, Ctrl snap; click / "
                    .. "Enter applies, right click / Esc cancels", "dim")
            if LV.on then ui.text("live: the object itself follows" .. (FC.freeze and " (the world runs meanwhile)" or ""), "dim")
            elseif LV.why ~= "" then ui.text(LV.why, "dim") end
        elseif sel then
            local ix = cur_ix()
            ui.text(sel.name .. ((not sel.added and sel.i) and fmt("   cell %05d%s", ix.cell[sel.i],
                                                                     ix.group[sel.i] and ", group" or "") or ""))
            if ui.button("Move (G)") then tool_begin(T_MOVE, K_EXISTING, sel, p) end
            ui.same_line()
            if ui.button("Rotate (R)") then tool_begin(T_ROTATE, K_EXISTING, sel, p) end
            ui.same_line()
            if ui.button("Scale (S)") then tool_begin(T_SCALE, K_EXISTING, sel, p) end
            ui.same_line()
            if ui.button("Duplicate (Shift+D)", {disabled = not can_copy(sel)}) then tool_begin(T_MOVE, K_COPY, sel, p) end
            if ui.button("Ground (End)") then edit_send(sel, "ground", "offset", 0) end
            ui.same_line()
            if ui.button("Delete (X X / Del)", {color = "#FF992626"}) then edit_send(sel, "remove"); S.sel = "" end
            ui.section("exact position, turn, scale", function() draw_selected(sel) end)
        else
            ui.text("click an object to select it (its box shows under the pointer)", "dim")
        end
        if ui.button("Place (Shift+A)", {disabled = S.prop == nil or M.tool ~= T_NONE}) then place_prop(p) end
        ui.same_line()
        ui.text(S.prop and S.prop.name or "(choose a prop in the panel's list)", "dim")
        if ui.button("Undo last (Ctrl+Z)", {disabled = last_edit() == 0 or M.tool ~= T_NONE}) then
            request("POST", "undo", {map = map_name()}, "undo")
        end
        local ls = resteep.world.live()
        if ls and ls.reload ~= "" then ui.text(ls.reload, "dim") end
        ui.section("keys", function()
            ui.text("View: middle mouse orbit, Shift+middle pan, wheel zoom, right mouse held: look and fly (WASD, "
                    .. "Q/E, wheel speed), Numpad . / F frame the selection. Click: select. G move, R rotate, S scale, "
                    .. "Shift+D duplicate, Shift+A place the prop, End onto the ground, X / Delete remove, Ctrl+Z "
                    .. "undo, Esc leave. In a tool: X / Y / Z lock to the map's axis, again to the object's own, "
                    .. "Shift+axis: the other two; type a number; Ctrl snaps; click / Enter applies, right click / "
                    .. "Esc cancels.", "dim")
        end)
    end)
end

local function edit_frame(p, dt)
    local ix = cur_ix()
    if not ix or ix.error then edit_stop(); return end
    local menu = resteep.info().menu_open
    local keys = not p.typing and not menu
    local g = near("edit", FC.pos, 400, S.all_kinds, 10, function(g) return g end)
    if S.select_newest and not S.busy then               -- a duplicate or a placed prop: select it
        local newest
        for n in pairs(W.added) do newest = max(newest or n, n) end
        if newest then S.sel = "a:" .. floor(newest) end
        S.select_newest = false
    end
    local sel = row_for_key(S.sel, FC.pos)
    local pivot = sel and {(sel.box.lo[1] + sel.box.hi[1]) / 2, (sel.box.lo[2] + sel.box.hi[2]) / 2,
                           (sel.box.lo[3] + sel.box.hi[3]) / 2}
    local tool = M.tool ~= T_NONE
    if tool and LV.on and live_gen() ~= LV.gen then      -- its cell was read again: the tool goes on (the overlay
        LV.gen = live_gen()                              -- puts the new objects where this mod put them)
    end
    FC.let_run = live_tick()                             -- the engine moves the object in its update only
    fc_update(keys and not tool, pivot, p, dt)
    local over_world = not p.over_ui and not menu
    if tool then
        if keys and not tool_keys(p) then tool = false end
        if tool then
            local head = tool_update(p)
            local w = (#head * 8 + 20) / max(p.w, 1)
            resteep.box(0.5 - w / 2, 0.01, w, 0.04, "#C814161C")
            resteep.text(0.5, 0.017, head, "#FFFFFFFF")
        end
    else
        local hover
        if over_world and FC.drag < 0 then
            local o, d = fc_ray(p.x, p.y)
            -- the smallest box the ray meets: a bench in front of a chalet's box is what the pointer means
            local best, bk = 1e30, nil
            local x0, y0, z0, x1, y1, z1 = g.x0, g.y0, g.z0, g.x1, g.y1, g.z1
            for k = 1, g.n do
                local vol = (x1[k] - x0[k]) * (y1[k] - y0[k]) * (z1[k] - z0[k])
                if vol < best then
                    local t = hit_box(x0[k], y0[k], z0[k], x1[k], y1[k], z1[k], o, d)
                    if t and t < 1500 then best, bk = vol, k end
                end
            end
            hover = bk and row_of(g, bk, FC.pos)
        end
        if hover and (not sel or hover.key ~= sel.key) then draw_object(hover, WHITE, 1.5, 1.5, LIMIT_HOVER) end
        if keys and over_world and p.clicks.left > 0 then
            if hover then select_row(hover) else S.sel = "" end
            sel = hover
        end
        if keys and FC.drag < 0 then
            local shift, ctrl = resteep.held("SHIFT"), resteep.held("CTRL")
            local now = resteep.time()
            if S.delete_armed ~= "" then                 -- X armed: anything but X / Enter / Delete disarms it
                local other = now >= S.delete_until
                for key in pairs(pressed) do
                    if key ~= "X" and key ~= "ENTER" and key ~= "DELETE" then other = true end
                end
                if other then
                    if sub(S.note, 1, 7) == "delete " then S.note = "" end
                    S.delete_armed = ""
                end
            end
            if pressed.ESCAPE then edit_stop(); return end
            if sel and not shift and not ctrl and pressed.G then tool_begin(T_MOVE, K_EXISTING, sel, p)
            elseif sel and not shift and not ctrl and pressed.R then tool_begin(T_ROTATE, K_EXISTING, sel, p)
            elseif sel and not shift and not ctrl and pressed.S then tool_begin(T_SCALE, K_EXISTING, sel, p)
            elseif sel and shift and pressed.D and can_copy(sel) then tool_begin(T_MOVE, K_COPY, sel, p)
            elseif shift and pressed.A then place_prop(p)
            elseif sel and not ctrl and (pressed.DELETE or (S.delete_armed == sel.key and now < S.delete_until and
                                                             (pressed.X or pressed.ENTER))) then
                S.delete_armed = ""
                edit_send(sel, "remove")
                S.note = "deleted " .. sel.name .. " (Ctrl+Z brings it back)"
                S.sel, sel = "", nil
            elseif sel and not ctrl and pressed.X then
                S.delete_armed = sel.key
                S.delete_until = now + 3
                S.note = "delete " .. sel.name .. "? X again or Enter: yes (3 s); any other key: no"
            elseif sel and pressed.END then
                edit_send(sel, "ground", "offset", 0)    -- onto the terrain under it (as Unreal's End)
            elseif ctrl and pressed.Z and last_edit() > 0 then
                request("POST", "undo", {map = map_name()}, "undo")   -- the server: your newest here
            elseif sel and (pressed.DECIMAL or pressed.F) then
                local r = 0
                for i = 1, 3 do r = max(r, (sel.box.hi[i] - sel.box.lo[i]) / 2) end
                fc_frame(pivot, r)
            end
        end
    end
    if sel and not (tool and M.kind == K_EXISTING) then      -- (beside a duplicate / place: fewer lines)
        draw_object(sel, YELLOW, 2, 2.5, tool and LIMIT_HOVER or LIMIT_SEL)
    end
    if S.edit then draw_tools(sel, p) end
end

-- ---- every frame ---------------------------------------------------------------------------------------------------
local function track_player()
    local pl = resteep.player()
    if not pl or not pl.x or abs(pl.x) > 1e5 or abs(pl.y) > 1e5 then S.have_pos = false; return end
    S.have_pos = true
    S.me = {pl.x, pl.y, pl.z}
    local a = S.anchor
    local dx, dy = a and pl.x - a[1] or 0, a and pl.y - a[2] or 0
    local d = sqrt(dx * dx + dy * dy)
    if not a or d > 60 then                              -- first sight, or a teleport
        S.anchor = {pl.x, pl.y}
    elseif d > 1.5 then
        S.heading, S.have_heading = atan(dy, dx), true
        S.anchor = {pl.x, pl.y}
    end
end

local function load_step()
    local map = map_name()
    local ix = IX[map]
    if not ix then ix = new_index(map); IX[map] = ix end
    if ix.done then return end
    local ok, err = coroutine.resume(ix.co)
    if not ok then ix.error = "the index could not be read: " .. tostring(err) end
    if not ok or coroutine.status(ix.co) == "dead" then
        ix.done, ix.co = true, nil
        S.prop = nil
        W_dirty = true
    end
end

-- the free camera's hotkey (the "edit_key" setting, F4 by default): in the game it enters the edit mode, again
-- leaves it (as Esc); not passed on to the edit mode's keys
local edit_key = nil
local function hotkey()
    if not edit_key then
        local ok, v = pcall(resteep.config.get, "edit_key")
        edit_key = (ok and type(v) == "string" and v ~= "") and v:upper() or "F4"
    end
    return edit_key
end
resteep.on("config_change", function() edit_key = nil end)

resteep.on("key", function(name)
    if type(name) == "string" and name:upper() == hotkey() then S.hotkey = true else pressed[name] = true end
end)

resteep.on("world_leave", function()
    if S.edit then edit_stop() end
    FC.frozen = false                                    -- the overlay let go of the world itself
end)

resteep.on("frame", function(dt)
    drawn = 0
    if not S.asked then
        S.asked = true
        load_content()
        request("GET", "edits", nil, "load")
        request("GET", "rules", nil, "rules")            -- what this server lets you do
    end
    if not S.map_chosen and not S.edit then             -- follow the world the game is in (a fast travel)
        local wm = world_map()
        if wm then set_map(wm) end
    end
    track_player()
    load_step()
    if W_dirty and cur_ix() then                         -- the content mods' edits first, as the session applied them
        W = fold({CONTENT or {}, S.edits}, map_name())
        W_dirty = false
        near_cache = {}
        mats_reset()
    end
    standin_tick(S.list_changed)
    live_net(S.list_changed)
    S.list_changed = false
    live_tick()
    if S.hotkey then
        S.hotkey = false
        local p = resteep.input.pointer()
        if not (p and p.typing) then
            if S.edit then edit_stop() else edit_start() end
        end
    end
    if S.edit then
        local p = resteep.input.pointer()
        if p then edit_frame(p, dt) end
    end
    local gh = S.ghost                                   -- the Add section's ghost, while that section shows
    if gh and resteep.time() - gh.t < 0.3 and M.tool == T_NONE then
        if not draw_ghost(gh.prop, gh.pos, gh.yaw, gh.scale, CYAN, 1.5) then
            local ix = cur_ix()
            local ex = S.prop and S.prop.name == gh.prop and S.prop.example
            if ix and ex and FC.on then draw_box(box_of_index(ix, ex, gh.yaw, gh.scale, gh.pos), CYAN, 2) end
        end
    end
    pressed = {}
end)

resteep.on("panel", function()
    local map, changed = ui.combo("map you ride in", MAPS, S.map, {width = 8})
    if changed then set_map(map); S.map_chosen = true end
    ui.text(S.status, status_color())
    local ix = IX[map_name()]
    if not ix or not ix.done then
        draw_position()
        ui.text("loading the " .. map_name() .. " index...", "dim")
        return
    end
    draw_position()
    if not ix.error then
        if ui.button(S.edit and "Leave the free camera" or "Free camera (edit with the mouse)") then
            if S.edit then edit_stop() else edit_start() end
        end
        ui.text(S.note ~= "" and S.note
                or "closes the menu; Esc comes back (in the game: " .. hotkey() .. " in and out)", "dim")
        ui.section("Add an object (experimental)", {open = true}, draw_add)
        ui.section("Objects near you", {open = true}, draw_nearby)
    else
        ui.text(ix.error, "bad")
    end
    ui.section("Edits", {open = true}, draw_edits)
end)

-- for tests (tests/test_world_editor_preview.py runs this file in a plain Lua with a stand-in resteep); the
-- overlay ignores what a mod's script returns
return {preview = P, fold = fold, obj_key = obj_key,
        outline = {parse = parse_outline, draw = draw_outline, draw_as = draw_as, corners = corners_of,
                   ghost = ghost_matrix, pick = pick_matrix, yaw = yaw_matrix,
                   reset = function() drawn = 0 end}}
