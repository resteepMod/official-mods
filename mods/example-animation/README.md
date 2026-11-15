# Example: Animations

`content.animations` (docs/modding/animations.md) without files of its own: the snowboard Indy plays the Truck
Driver double grab (a setting switches it), and the ski Mute plays one and a half times as fast. Copy the folder to a
name without the leading `_` to load it.

For an animation of your own: `python -m resteep anims export ID00_PS00_male_GRAB_INDY`, edit it in Blender (the
scene at 60 fps), export a `.glb` into `anims/` and add `{"replace": "ID00_PS00_male_GRAB_INDY", "file":
"anims/indy.glb"}`.

`main.lua` shows `resteep.rider.play_anim`: F10 turns the snowboard Melon (every clip of it, both riders) into a Nosegrab while it is
on, F10 again gives the Melon back. A script decides when, the game still decides the moment of the grab.
