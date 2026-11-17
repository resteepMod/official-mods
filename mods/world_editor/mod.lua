-- World editor, server half: keeps the list of world edits (objects added, moved, turned, scaled, removed) that
-- players make in the overlay's World editor panel (the client half, src/world_editor.cpp), and hands it to the
-- session step (apply.py) that turns it into edited world cells at the next game start. See README.md.
--
--   GET  /_powder/world_editor/edits   {"version": 1, "next": N, "edits": [edit, ...]}   (oldest first)
--   POST /_powder/world_editor/edits   body: one edit (below) -> the same, with the new edit numbered
--   POST /_powder/world_editor/undo    body: {"n": N} or {"map": M} (the caller's own newest edit, of that map)
--                                      -> the same; an added object's own later edits go with it
--   POST /_powder/world_editor/clear   body: {"map": "Alpes"} -> the same, without that map's edits (admins only)
--   POST /_powder/world_editor/purge   body: {"by": profile id} -> the same, without that player's edits (admins)
--   GET  /_powder/world_editor/rules   the server's rules (below) and what the caller may do
--   POST /_powder/world_editor/rules   body: rules to change (admins only) -> the same
--
-- An edit: {map, op, ...} with map one of MAPS and op
--   add     src = {layer, cell, id}  (a shipped entity that is copied), name, pos = {x, y, z}, yaw (deg), scale;
--           or model = name instead of src: a custom model of a content mod (tools/forge/models.py)
--   move    pos = {x, y, z}          the object's new origin
--   turn    deg                      about Z, counter-clockwise seen from above
--   rotate  axis = "x"|"y"|"z", deg, local (bool)   about the map's axis through the object's origin, or (local)
--                                    about the object's own axis
--   scale   factor                   about its origin
--   remove
-- For move/turn/scale/remove the object is either a shipped one, obj = {layer, cell, id, name}, or one an earlier
-- edit added, of = <that edit's n>. Positions are metres in the map's coordinates (Z up), ids "0x..." hex.
--
-- Stored with api.save (the server's database, scope mod:world_editor). Who edits (docs/todo/11-shared-world-
-- editing.md): the in-game menu sends the player's menu ticket, so req.player names them (verified by the server);
-- the rules' base is config.toml's [mods.settings.world_editor] (api.settings), admins' changes override it;
-- every edit keeps its author (by, by_name). The server's own PC without a player counts as its host (an admin), as
-- before. The rules (api.save "rules", changed by admins): edit = "admins" (default) | "everyone" | "off",
-- undo_others (default true: a player may undo / change another player's edits), shipped_objects (default true:
-- players may move, turn, scale, remove the game's own objects), max_adds / max_edits per player (0 = no limit),
-- blocked_props (prop names players may not place). Admins ([server] admins) may always do everything; clear is
-- theirs only. Reading is open (the list is no secret: it is what the world looks like).

local MAX_EDITS = 2000
local MAX_BODY = 4096
local MAPS = { Alpes = true, Japan = true, Alaska = true, WhiteRoom = true }
local OPS = { add = true, move = true, turn = true, rotate = true, scale = true, remove = true, ground = true }
local AXES = { x = true, y = true, z = true }
local CONTENT_N = 1000000      -- edit numbers from here on are content mods' (tools/forge/compose.py own_edits)

return function(api)
    local DEFAULT_RULES = { edit = "admins", undo_others = true, shipped_objects = true, max_adds = 0, max_edits = 0,
                            blocked_props = {} }
    local EDIT_MODES = { admins = true, everyone = true, off = true }
    local rules = {}                                   -- defaults, then config.toml's, then the admins' changes
    for k, v in pairs(DEFAULT_RULES) do rules[k] = v end
    local edits = api.load("edits", {})
    local next_n = api.load("next", 1)
    for _, e in ipairs(edits) do                  -- a list saved by an older copy without "next"
        if e.n >= next_n then next_n = e.n + 1 end
    end

    local function listing()
        local parts = {}
        for i, e in ipairs(edits) do parts[i] = api.json.encode(e) end
        -- blocked_props goes along: the players' builds (world.py apply --blocked) check the real prop names, which
        -- this server cannot (a modified client may send any name); an admin's edit (admin = true) is exempt
        return '{"version": 1, "next": ' .. next_n .. ', "blocked_props": ' .. api.json.encode(rules.blocked_props or {})
            .. ', "edits": [' .. table.concat(parts, ", ") .. ']}'
    end

    local function reply(status, body)
        return { status = status, body = body, content_type = "application/json",
                 headers = { ["Cache-Control"] = "no-store" } }
    end

    local function fail(status, message)
        return reply(status, api.json.encode({ ok = false, error = message }))
    end

    local function store()
        api.save("edits", edits)
        api.save("next", next_n)
    end

    -- checks; each returns the clean value or nil, why
    local function number(v, lo, hi)
        if type(v) ~= "number" or v ~= v or v < lo or v > hi then return nil end
        return v + 0.0
    end

    local function integer(v, lo, hi)
        if math.type(v) == "float" and v == math.floor(v) then v = math.tointeger(v) end
        if math.type(v) ~= "integer" or v < lo or v > hi then return nil end
        return v
    end

    local function position(v)
        if type(v) ~= "table" then return nil end
        local out = {}
        for i = 1, 3 do
            out[i] = number(v[i], -20000, 20000)
            if not out[i] then return nil end
        end
        return out
    end

    local function text(v)
        if type(v) ~= "string" then return "" end
        return (string.gsub(string.sub(v, 1, 120), "[^%w_%-%.%s#]", "?"))
    end

    local function object_ref(v)
        if type(v) ~= "table" or type(v.id) ~= "string" or #v.id > 18 or not string.match(v.id, "^0x%x+$") then
            return nil
        end
        local layer, cell = integer(v.layer or 0, 0, 3), integer(v.cell, 0, 100000)
        if not layer or not cell then return nil end
        return { layer = layer, cell = cell, id = string.lower(v.id), name = text(v.name) }
    end

    local function find(n)
        for i, e in ipairs(edits) do
            if e.n == n then return i, e end
        end
    end

    local function check(body)
        if type(body) ~= "table" then return nil, "an edit is a JSON object" end
        local map, op = body.map, body.op
        if not MAPS[map] then return nil, "unknown map" end
        if not OPS[op] then return nil, "unknown op" end
        local e = { map = map, op = op, t = os.time() }
        if op == "add" then
            if type(body.model) == "string" and body.src == nil then
                e.model = string.match(body.model, "^[%w_][%w_%.%-]*$") and string.sub(body.model, 1, 63) or nil
                if not e.model then return nil, "model: a name of letters, digits, _ . -" end
            else
                e.src = object_ref(body.src)
            end
            e.pos = position(body.pos)
            e.yaw = number(body.yaw or 0, -360, 360)
            e.scale = number(body.scale or 1, 0.05, 20)
            e.name = text(body.name)
            if body.ground ~= nil then              -- on the terrain under pos, this many metres up (world.py apply)
                e.ground = number(body.ground, -100, 100)
                if not e.ground then return nil, "ground: an offset in metres (-100 to 100)" end
            end
            if not (e.src or e.model) or not e.pos or not e.yaw or not e.scale then
                return nil, "add needs src (or model), pos, yaw, scale"
            end
            return e
        end
        if body.of ~= nil then
            local of = integer(body.of, 1, math.maxinteger)
            local _, target = find(of or -1)
            -- n >= CONTENT_N: an object a content mod adds (compose.py numbers them; the session applies them first)
            if (not target or target.op ~= "add" or target.map ~= map) and not (of and of >= CONTENT_N) then
                return nil, "of: no such added object"
            end
            e.of = of
        else
            e.obj = object_ref(body.obj)
            if not e.obj then return nil, "obj needs layer, cell, id" end
        end
        if op == "move" then
            e.pos = position(body.pos)
            if not e.pos then return nil, "move needs pos" end
        elseif op == "turn" then
            e.deg = number(body.deg, -360, 360)
            if not e.deg then return nil, "turn needs deg" end
        elseif op == "rotate" then
            e.deg = number(body.deg, -360, 360)
            e.axis = AXES[body.axis] and body.axis or nil
            e["local"] = body["local"] == true
            if not e.deg or not e.axis then return nil, "rotate needs axis (x, y, z) and deg" end
        elseif op == "scale" then
            e.factor = number(body.factor, 0.05, 20)
            if not e.factor then return nil, "scale needs factor" end
        elseif op == "ground" then                  -- onto the terrain under it (world.py apply reads the .tbf)
            e.offset = number(body.offset or 0, -100, 100)
            if not e.offset then return nil, "ground: offset in metres (-100 to 100)" end
        end
        return e
    end

    local function body_of(req)
        if #req.body > MAX_BODY then return nil end
        local v = api.json.decode(req.body ~= "" and req.body or "{}")
        return v
    end

    local function local_peer(peer)
        return peer == "127.0.0.1" or peer == "::1" or string.match(peer or "", "^::ffff:127%.") ~= nil
    end

    -- who sends a change: the verified player, or the server's own PC (its host) without one; nil = nobody
    local function who(req)
        if type(req.player) == "table" and type(req.player.profile_id) == "string" then
            return { pid = req.player.profile_id, name = req.player.name or "", admin = req.player.admin == true }
        end
        -- this PC is the host only without any ticket (a refused one is false) and not on a [server] public server,
        -- which may be reached through a tunnel that makes every guest loopback
        local public = type(api.config.server) == "table" and api.config.server.public == true
        if req.player == nil and local_peer(req.peer) and not public then
            return { pid = "host", name = "host", admin = true }
        end
        return nil
    end

    local function count_of(pid)
        local adds, all = 0, 0
        for _, x in ipairs(edits) do
            if x.by == pid then
                all = all + 1
                if x.op == "add" then adds = adds + 1 end
            end
        end
        return adds, all
    end

    local function blocked(name)
        for _, b in ipairs(rules.blocked_props or {}) do
            if type(b) == "string" and b ~= "" and name and string.find(string.lower(name), string.lower(b), 1, true) then
                return true
            end
        end
        return false
    end

    -- whether `w` may make edit `e` (checked, not yet stored): nil, or why not
    local function refused(w, e)
        if w.admin then return nil end
        if rules.edit ~= "everyone" then
            return rules.edit == "off" and "editing is off on this server" or "only the server's admins edit here"
        end
        if e.op == "add" and blocked(e.name) then return "this prop is not allowed on this server" end
        if e.obj and not rules.shipped_objects then return "the game's own objects can't be changed here" end
        if e.of then
            local _, target = find(e.of)
            if target and target.by and target.by ~= w.pid and not rules.undo_others then
                return "that object is another player's"
            end
        end
        local adds, all = count_of(w.pid)
        if (rules.max_edits or 0) > 0 and all >= rules.max_edits then
            return "you have made the most edits allowed here (" .. rules.max_edits .. ")"
        end
        if e.op == "add" and (rules.max_adds or 0) > 0 and adds >= rules.max_adds then
            return "you have placed the most objects allowed here (" .. rules.max_adds .. ")"
        end
        return nil
    end

    local function rules_view(w)
        local r = {}
        for k, v in pairs(rules) do r[k] = v end
        r.you = w and { name = w.name, admin = w.admin, may_edit = w.admin or rules.edit == "everyone" } or nil
        return api.json.encode(r)
    end

    local function apply_rules(target, body)
        local rules = target
        if body.edit ~= nil then
            if not EDIT_MODES[body.edit] then return "edit: admins, everyone or off" end
            rules.edit = body.edit
        end
        for _, k in ipairs({ "undo_others", "shipped_objects" }) do
            if body[k] ~= nil then
                if type(body[k]) ~= "boolean" then return k .. ": true or false" end
                rules[k] = body[k]
            end
        end
        for _, k in ipairs({ "max_adds", "max_edits" }) do
            if body[k] ~= nil then
                local v = integer(body[k], 0, MAX_EDITS)
                if not v then return k .. ": 0 (no limit) to " .. MAX_EDITS end
                rules[k] = v
            end
        end
        if body.blocked_props ~= nil then
            if type(body.blocked_props) ~= "table" or #body.blocked_props > 200 then return "blocked_props: a list" end
            local list = {}
            for i, b in ipairs(body.blocked_props) do
                if type(b) ~= "string" or #b > 120 then return "blocked_props: names" end
                list[i] = b
            end
            rules.blocked_props = list
        end
        return nil
    end

    local function change_rules(body)
        local why = apply_rules(rules, body)
        if why then return why end
        local changed = api.load("rules", {})           -- only what admins changed is stored (config.toml stays the base)
        for k in pairs(DEFAULT_RULES) do
            if body[k] ~= nil then changed[k] = rules[k] end
        end
        api.save("rules", changed)
        return nil
    end

    do                                                 -- [mods.settings.world_editor] in config.toml, then the stored
        local from_config = type(api.settings) == "table" and api.settings or {}
        local why = apply_rules(rules, from_config)
        if why then api.log.warn("config.toml [mods.settings.world_editor]:", why, "(the defaults are used)") end
        local why2 = apply_rules(rules, api.load("rules", {}))
        if why2 then api.log.warn("the stored rules:", why2) end
    end

    api.before_http("*", "/_powder/world_editor/*", function(req)
        local path, method = req.path, req.method
        if path == "/_powder/world_editor/edits" and method == "GET" then
            return reply(200, listing())
        end
        local w = who(req)
        if path == "/_powder/world_editor/rules" and method == "GET" then
            return reply(200, rules_view(w))
        end
        local action = string.match(path, "^/_powder/world_editor/(%a+)$")
        if method ~= "POST" or not (action == "edits" or action == "undo" or action == "clear" or action == "rules"
                                    or action == "purge") then
            return fail(404, "not found")
        end
        if not w then
            return fail(403, "sign in with ReSteep's launcher to edit (no player with this request)")
        end
        local body = body_of(req)
        if type(body) ~= "table" then return fail(400, "the body is not a JSON object") end
        if action == "purge" then                      -- every edit of one player (and what hangs on their adds)
            if not w.admin then return fail(403, "only the server's admins remove a player's edits") end
            if type(body.by) ~= "string" or body.by == "" then return fail(400, "purge needs by (a player's id)") end
            local gone_adds, kept = {}, {}
            for _, x in ipairs(edits) do
                if x.by == body.by and x.op == "add" then gone_adds[x.n] = true end
            end
            for _, x in ipairs(edits) do
                if x.by ~= body.by and not (x.of and gone_adds[x.of]) then kept[#kept + 1] = x end
            end
            api.log.info(w.name, "removed", #edits - #kept, "edit(s) of", body.by)
            edits = kept
            store()
            return reply(200, listing())
        end
        if action == "rules" then
            if not w.admin then return fail(403, "only the server's admins change its rules") end
            local why = change_rules(body)
            if why then return fail(400, why) end
            api.log.info("rules changed by", w.name)
            return reply(200, rules_view(w))
        end

        if action == "edits" then
            if #edits >= MAX_EDITS then return fail(409, "too many edits (" .. MAX_EDITS .. "): undo or clear some") end
            local e, why = check(body)
            if not e then return fail(400, why) end
            why = refused(w, e)
            if why then return fail(403, why) end
            e.by, e.by_name = w.pid, w.name
            e.admin = w.admin or nil                   -- may place what blocked_props names (the builds check it)
            e.n = next_n
            next_n = next_n + 1
            edits[#edits + 1] = e
            store()
            api.log.info("edit", e.n, "by", w.name, e.map, e.op, e.name or (e.obj and (e.obj.name ~= "" and e.obj.name or e.obj.id))
                         or ("of " .. tostring(e.of)))
        elseif action == "undo" then
            local n = body.n ~= nil and integer(body.n, 1, math.maxinteger) or nil
            if not n then                              -- the caller's own newest edit (of body.map, when given)
                for k = #edits, 1, -1 do
                    local x = edits[k]
                    if (x.by == w.pid or (w.admin and x.by == nil)) and (body.map == nil or x.map == body.map) then
                        n = x.n
                        break
                    end
                end
            end
            local i, e = find(n or -1)
            if not i then return fail(404, "no such edit") end
            if not w.admin then
                if rules.edit ~= "everyone" then return fail(403, "only the server's admins edit here") end
                if e.by ~= w.pid and not rules.undo_others then return fail(403, "that edit is another player's") end
            end
            local kept, gone = {}, 0
            for _, x in ipairs(edits) do
                if x.n == e.n or (e.op == "add" and x.of == e.n) then gone = gone + 1 else kept[#kept + 1] = x end
            end
            edits = kept
            store()
            api.log.info("undid edit", e.n, e.map, e.op, "(" .. gone .. " edit(s) gone)")
        else
            if not w.admin then return fail(403, "only the server's admins clear a map") end
            if not MAPS[body.map] then return fail(400, "unknown map") end
            local kept = {}
            for _, x in ipairs(edits) do
                if x.map ~= body.map then kept[#kept + 1] = x end
            end
            api.log.info("cleared", #edits - #kept, "edit(s) of", body.map)
            edits = kept
            store()
        end
        return reply(200, listing())
    end)
    api.log.info("world editor:", #edits, "edit(s) stored; next game start applies them (mods/world_editor)")
end
