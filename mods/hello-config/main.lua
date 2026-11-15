-- Hello Config: a ReSteep mod. The API is documented in MODDING.md; your settings are in resteep.config.
local function strength() return resteep.config.get("strength") end

resteep.on("key", function(name)
  if name == "F9" and resteep.config.get("enabled_effect") then
    resteep.notify(("Hello Config: strength %.1f"):format(strength()), 2)
  end
end)

resteep.on("config_change", function(key, value)
  resteep.log(key .. " is now " .. tostring(value))
end)
