-- shared diagnostics behind the display front-end HUDs (roblox + browser build their per-second status lines from the same fps window and game-state addresses).

local Hud = {}

-- silent hill game-state globals.  gs is the game's own state machine (7 =
-- main menu, 11 = in-game); fc is its frame counter.
local SH_GATEWAY = 0x800BC728
Hud.gsAddr = SH_GATEWAY + 0x594
Hud.fcAddr = 0x800225D0

-- 1-second fps window: call tick(now) once per captured frame; fps recomputes each full second of wall time, otherwise keeps its value.
local HudFpsMeter = {}
HudFpsMeter.__index = HudFpsMeter

function HudFpsMeter:tick(now)
	self.frames += 1
	if now - self.windowStart >= 1.0 then
		self.fps = self.frames / (now - self.windowStart)
		self.windowStart = now
		self.frames = 0
	end
	return self.fps
end

function Hud.newFpsMeter()
	return setmetatable({
		fps = 0,
		windowStart = os.clock(),
		frames = 0,
	}, HudFpsMeter)
end

return Hud
