-- Checkpoint race: build a course where you ride, race it, compare times on the server.
--   F5        add a checkpoint where you are (the first is the start, the last the finish)
--   F6        remove the last checkpoint      Shift+F6  remove the whole course
--   F7        back to the start (teleport; only on the ground)
-- The clock starts when you leave the start and stops at the finish; every checkpoint in between must be passed
-- in order. Times go to the server's leaderboard for this course (each course has its own board).
-- A run in which a mod held the rider (a helicopter, a drone), the world was frozen, or the rider jumped further
-- than riding goes in one frame (a teleport) is timed but not sent.

local RADIUS = 12            -- metres around a checkpoint that count as "passed"
local JUMP, MAX_SPEED = 25, 150   -- a move beyond JUMP m + MAX_SPEED m/s * the frame's time is a teleport
local course = {}            -- {x, y, z} ...
local race = nil             -- {next = index, started = time, splits = {...}, last = {x, y, z, t}, foul = why}
local result = nil           -- what the last finish showed: {lines, until}

local function course_id()
    -- the board's name: a hash of the rounded checkpoints, so every course has its own times
    local h = 5381
    for _, c in ipairs(course) do
        for _, v in ipairs({c.x, c.y, c.z}) do
            for ch in tostring(math.floor(v + 0.5)):gmatch(".") do h = (h * 33 + ch:byte()) % 4294967296 end
        end
    end
    return string.format("c%d_%08x", #course, h)
end

local function store()
    resteep.save({course = course})
end

local function rebuild_zones()
    for i = 1, 64 do resteep.remove_zone("cp" .. i) end
    for i, c in ipairs(course) do resteep.zone("cp" .. i, c.x, c.y, c.z, RADIUS) end
end

local function fmt(t)
    return string.format("%d:%05.2f", math.floor(t / 60), t % 60)
end

local function label(i)
    if i == 1 then return "START" elseif i == #course then return "FINISH" else return "CP " .. (i - 1) end
end

local saved = resteep.load()
if saved and type(saved.course) == "table" then course = saved.course end
rebuild_zones()

resteep.on("key", function(key)
    local p = resteep.player()
    if key == "F5" then
        if not p then resteep.notify("No rider found", 2) return end
        if #course >= 64 then resteep.notify("At most 64 checkpoints", 2) return end
        course[#course + 1] = {x = p.x, y = p.y, z = p.z}
        race = nil
        rebuild_zones(); store()
        resteep.notify(#course == 1 and "Start set" or ("Checkpoint " .. #course .. " set (finish)"), 2)
    elseif key == "F6" then
        if resteep.held("SHIFT") then course = {} else course[#course] = nil end
        race = nil
        rebuild_zones(); store()
        resteep.notify(#course == 0 and "Course removed" or ("Removed, " .. #course .. " left"), 2)
    elseif key == "F7" then
        local s = course[1]
        if not s then resteep.notify("No course yet: F5 adds checkpoints", 3) return end
        race = nil
        if not resteep.teleport(s.x, s.y, s.z + 1.5, 0, 0, 0) then
            resteep.notify("Teleport not possible right now", 2)
        end
    end
end)

resteep.on("zone_exit", function(name)
    if name == "cp1" and #course >= 2 then
        race = {next = 2, started = resteep.time(), splits = {}}
        resteep.notify("GO!", 1)
    end
end)

resteep.on("zone_enter", function(name)
    local i = tonumber(name:sub(3))
    if not i or #course < 2 then return end
    local t = resteep.time()
    if i == 1 then
        race = nil                                    -- back at the start: the clock starts again on leaving it
    elseif race and i == race.next then
        local split = t - race.started
        race.splits[#race.splits + 1] = split
        if i == #course then
            local time, foul = split, race.foul
            race = nil
            result = {lines = {"FINISH  " .. fmt(time)}, ["until"] = t + 10}
            if foul then
                result.lines[2] = "(not sent to the server: " .. foul .. ")"
                return
            end
            resteep.post("/mods/board/submit",
                {board = course_id(), value = time, lower_is_better = true, detail = {checkpoints = #course}},
                function(ok, reply)
                    result = result or {lines = {"FINISH  " .. fmt(time)}}
                    result["until"] = resteep.time() + 12
                    if not ok or type(reply) ~= "table" then
                        result.lines[#result.lines + 1] = "(not on the server: " .. tostring(reply) .. ")"
                        return
                    end
                    result.lines[1] = string.format("FINISH  %s   #%d of %d%s", fmt(time), reply.rank or 0,
                        reply.players or 0, reply.improved and "  NEW BEST" or "")
                    for i, e in ipairs(reply.top or {}) do
                        if i > 5 then break end
                        result.lines[#result.lines + 1] = string.format("%d. %-16s %s", e.rank or i,
                            tostring(e.name or "?"), fmt(tonumber(e.value) or 0))
                    end
                end)
        else
            race.next = i + 1
            resteep.notify(label(i) .. "  " .. fmt(split), 1.5)
        end
    end
end)

local crashed = -100         -- the game's respawn after a crash moves the rider: no teleport
resteep.on("crash", function() crashed = math.huge end)
resteep.on("crash_end", function() crashed = resteep.time() end)

-- What makes a run not count (nil: it counts so far).
local function check_foul(p, t)
    if p.held then return "a mod held the rider" end
    local w = resteep.world.get()
    if w and w.frozen then return "the world was frozen" end
    local l = race.last
    if l and t - crashed > 3 then
        local d = math.sqrt((p.x - l.x) ^ 2 + (p.y - l.y) ^ 2 + (p.z - l.z) ^ 2)
        if d > JUMP + MAX_SPEED * (t - l.t) then return string.format("the rider jumped %.0f m", d) end
    end
end

resteep.on("frame", function()
    local p = resteep.player()
    local t = resteep.time()
    if race then
        if p then
            race.foul = race.foul or check_foul(p, t)
            race.last = {x = p.x, y = p.y, z = p.z, t = t}
        else
            race.last = nil                           -- no rider this frame (a sport change): compare afresh
        end
    end
    for i, c in ipairs(course) do
        local col = (race and i == race.next) and "#FFD34E" or "#5EC8F2"
        resteep.marker(c.x, c.y, c.z, label(i), col)
    end
    if race then
        resteep.text(0.5, 0.06, fmt(t - race.started), race.foul and "#B0BCC8" or "#FFFFFF", 2.2)
        if race.foul then resteep.text(0.5, 0.16, "NOT COUNTED: " .. race.foul, "#B0BCC8", 0.9) end
        local c = course[race.next]
        if p and c then
            local d = math.sqrt((c.x - p.x) ^ 2 + (c.y - p.y) ^ 2 + (c.z - p.z) ^ 2)
            resteep.text(0.5, 0.12, string.format("%s  %.0f m", label(race.next), d), "#FFD34E", 1.1)
        end
    elseif #course > 0 and p then
        local c = course[1]
        local d = math.sqrt((c.x - p.x) ^ 2 + (c.y - p.y) ^ 2 + (c.z - p.z) ^ 2)
        if d < 400 then
            resteep.text(0.5, 0.06, string.format("COURSE  %d CHECKPOINTS   START %.0f m   (F7: go there)", #course, d),
                "#B0BCC8", 0.9)
        end
    end
    if result then
        if t > result["until"] then result = nil
        else
            resteep.box(0.36, 0.2, 0.28, 0.05 + 0.032 * #result.lines, "#C00E1620")
            for i, line in ipairs(result.lines) do resteep.text(0.5, 0.215 + 0.032 * (i - 1), line, i == 1 and "#FFFFFF" or "#B0BCC8") end
        end
    end
end)

resteep.log(#course > 0 and ("course with " .. #course .. " checkpoints loaded") or "no course yet (F5 adds checkpoints)")
