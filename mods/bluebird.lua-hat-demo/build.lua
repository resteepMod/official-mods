-- Lua Hat Demo: the hat's model and texture are made here, from the mod's settings (MOD_FORMAT.md "Build scripts").
-- Metres, y up; the hat slot's box is x -0.10..0.11, y 1.64..1.87, z -0.10..0.16 (content-modding/examples/hats/hats_box.glb).
local cfg = resteep.config
local cx, base, cz, r = 0.0, 1.655, 0.03, 0.104

local hat = resteep.mesh()
hat:cylinder(cx, base, cz, r, 0.10, 40)                   -- the band
local dome = resteep.mesh():sphere(0, 0, 0, r, 40, 20):scale(1, 0.7, 1):translate(cx, base + 0.10, cz)
hat:append(dome)
if cfg.get("pompom") then
  hat:append(resteep.mesh():sphere(cx, base + 0.10 + r * 0.7 + 0.02, cz, 0.035, 16, 10))
end

local tex = resteep.image(512, 512, cfg.get("color"))
local n = math.floor(cfg.get("stripes") or 0)
for i = 1, n do                                         -- horizontal stripes over the band (v runs up the cylinder)
  tex:rect(0, 40 + (i - 1) * 56, 512, 24, cfg.get("stripe"))
end
tex:noise(11, 6)

resteep.item{key = "beanie", slot = "hats", title = "Lua Beanie", model = hat,
              textures = {diffuse = tex, normal = resteep.image(64, 64, "#8080ff")}}
resteep.log("beanie:", hat:counts())
