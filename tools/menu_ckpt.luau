-- Silent Hill checkpoint workflow for the interactive front-ends.  the browser front-end resumes
-- checkpoints/sh_gs_7.bin (a save at the game's main menu, gs==7) by default; that file is
-- gitignored and machine-local, so this tool regenerates and validates it.
--   lune run tools/menu_ckpt.luau capture [out] [cpi] [maxSeconds]   -- boot the real bios (it
--       installs the ram interrupt vectors the game needs), direct-load SLUS_007.07, run until gs==7
--   lune run tools/menu_ckpt.luau resume <in> [out] [cpi] [maxSeconds] -- continue until gs==7
--   lune run tools/menu_ckpt.luau verify <ckpt>  -- confirm a live main menu: gs stays 7, fc
--       advances, and a non-black frame packs.
-- direct loading needs a runtime whose bios kernel already ran (loading the exe on a cold runtime
-- wedges the boot in the exception vector); cpi 16 is the conservative speed/accuracy trade-off.
local fs = require("@lune/fs")
local process = require("@lune/process")
local Boot = require("./lib/boot")
local Loader = require("./lib/ps1loader")
local requirePs1 = Loader.createRequire()
local Hud = requirePs1("Hud")
local Disc = requirePs1("Disc")
local FrameOut = requirePs1("FrameOut")

local args = process.args or {}
local mode = args[1]
local DEFAULT_CKPT = "checkpoints/sh_gs_7.bin"

local gsAddr = Hud.gsAddr
local fcAddr = Hud.fcAddr
local MENU_STATE = 0x800A9A74
local MENU_SEL = 0x800A9A78

local function u32(mem, a)
	return mem:read32(a) or 0
end

local function boot(cpi, checkpoint)
	local _boot = require("./lib/boot").boot({
		cpuCyclesPerInstruction = cpi,
		useBlocks = true,
		checkpoint = checkpoint,
	})
	return _boot
end

-- run `frames` emulated frames (vblank intervals), mirroring play.luau pacing.
local function runFrames(runtime, frames)
	local result = Boot.runFrames(runtime, frames, 20000000)
	if result == "guard" then
		print("[menu_ckpt] frame guard hit (20M steps without a vblank)")
		return false
	end
	return result == "ok" and not runtime.cpu.halted
end

local function probes(mem)
	return string.format("pc=%08X fc=%d gs=%d ms=%d sel=%d tick=%d",
		mem.cpu.pc or 0, u32(mem, fcAddr), u32(mem, gsAddr), u32(mem, MENU_STATE),
		u32(mem, MENU_SEL), mem.timers.vblankTick or 0)
end

-- run until gs==7 (main menu); save whatever state is reached when the menu
-- appears or the wall budget / stall guard trips.
local function runToMenu(_boot, maxWallSeconds, outPath)
	local runtime = _boot.runtime
	local mem = _boot.mem
	local startWall = os.clock()
	local lastTick = mem.timers.vblankTick or 0
	local frames = 0
	local lastAdvanceWall = startWall
	local gsMax = -1
	local lastLog = ""

	local function line(tag)
		local s = string.format("[menu_ckpt] %-6s wall=%5.1fs emuFrames=%6d %s",
			tag, os.clock() - startWall, frames, probes(mem))
		if s ~= lastLog then
			print(s)
			lastLog = s
		end
	end


	line("start")

	while true do
		local now = os.clock()
		if now - startWall >= maxWallSeconds then
			print("[menu_ckpt] wall budget exhausted")
			break
		end
		if runtime.cpu.halted then
			print("[menu_ckpt] cpu halted")
			break
		end
		if now - lastAdvanceWall >= 90 then
			print("[menu_ckpt] stalled (no vblank advance for 90s wall)")
			break
		end

		local target = lastTick + 1
		if not runFrames(runtime, 1) then
			break
		end
		if (mem.timers.vblankTick or 0) >= target then
			lastAdvanceWall = os.clock()
		end
		lastTick = mem.timers.vblankTick or target
		frames += 1
		if frames % 30 == 0 then
			line("run")
		end

		local gs = u32(mem, gsAddr)
		local fc = u32(mem, fcAddr)
		if gs > gsMax then gsMax = gs end
		if gs == 7 and fc > 0 and frames > 30 then
			line("menu")
			-- let the menu settle for two emulated seconds before saving so
			-- the save includes live state (input + demo timer active).
			if not runFrames(runtime, 120) then
				break
			end
			local n = _boot.ckpt.save(runtime, outPath, fs.writeFile)
			print(string.format("[menu_ckpt] SAVED menu checkpoint (%d bytes) to %s (gs=7 fc=%d frames=%d wall=%.1fs)",
				n, outPath, u32(mem, fcAddr), frames, os.clock() - startWall))
			return
		end
	end

	line("final")
	local n = _boot.ckpt.save(runtime, outPath, fs.writeFile)
	print(string.format("[menu_ckpt] SAVED interim checkpoint (%d bytes) to %s (gsMax=%d frames=%d wall=%.1fs)",
		n, outPath, gsMax, frames, os.clock() - startWall))
end

local function cmdCapture(outPath, cpi, maxSeconds)
	local _boot = boot(cpi, nil)
	print(string.format("[menu_ckpt] capture: 4s bios probe then direct boot of SLUS_007.07 cpi=%d", cpi))
	-- run the bios kernel briefly so its ram vectors / interrupt dispatch are
	-- installed before the game exe loads on top of it (see header note).
	local probeStart = os.clock()
	local guard = 0
	while os.clock() - probeStart < 4 and guard < 20000000 do
		if not _boot.runtime:step() then break end
		guard += 1
	end
	print(string.format("[menu_ckpt] bios probe ran %.1fs", os.clock() - probeStart))
	local exe, loadErr = Disc.loadExecutableFromDisc(_boot.readSector)
	if not exe then
		error("loadExecutableFromDisc failed: " .. tostring(loadErr))
	end
	_boot.runtime:loadExecutable(exe.data)
	runToMenu(_boot, maxSeconds, outPath)
end

local function cmdResume(ckptIn, outPath, cpi, maxSeconds)
	local _boot = boot(cpi, ckptIn)
	print(string.format("[menu_ckpt] resume %s -> %s cpi=%d", ckptIn, outPath, cpi))
	runToMenu(_boot, maxSeconds, outPath)
end

local function cmdVerify(ckptPath)
	local _boot = boot(64, ckptPath)
	local runtime = _boot.runtime
	local mem = _boot.mem
	local gs, fc = u32(mem, gsAddr), u32(mem, fcAddr)
	print(string.format("[menu_ckpt] verify: loaded %s gs=%d fc=%d %s", ckptPath, gs, fc, probes(mem)))
	if gs ~= 7 then
		error(string.format("checkpoint is not at the main menu (gs=%d, want 7)", gs))
	end
	if not runFrames(runtime, 60) then
		error("cpu halted during verification run")
	end
	local gs2, fc2 = u32(mem, gsAddr), u32(mem, fcAddr)
	if gs2 ~= 7 then
		error("game left the main menu during verification (gs=" .. gs2 .. ")")
	end
	if fc2 <= fc then
		error("frame counter did not advance during verification")
	end
	local payload, w, h = FrameOut.packFrame(mem.gpu)
	if not payload or #payload <= 8 then
		error("packFrame produced no frame")
	end
	-- sample the top-left 64x64 block for any non-black pixel: the menu is
	-- drawn there on the menu checkpoint's display geometry.
	local nonzero = 0
	for i = 9, math.min(#payload, 8 + 64 * 64 * 4), 4 do
		if payload:byte(i) ~= 0 or payload:byte(i + 1) ~= 0 or payload:byte(i + 2) ~= 0 then
			nonzero += 1
		end
	end
	print(string.format("[menu_ckpt] verify: gs=%d stable, fc %d -> %d, frame %dx%d bytes=%d nonzero-corner=%d",
		gs2, fc, fc2, w, h, #payload, nonzero))
	if nonzero == 0 then
		error("frame sample is entirely black; the menu is not rendering")
	end
	print("[menu_ckpt] VERIFY OK: checkpoint is a live, rendering main menu")
end

local function usage()
	print("usage: lune run tools/menu_ckpt.luau <capture|resume|verify> [args]")
	print("  capture [out] [cpi] [maxSeconds]   boot to the main menu and save (default out " .. DEFAULT_CKPT .. ")")
	print("  resume <in> [out] [cpi] [maxSeconds]  continue a checkpoint to the main menu and save")
	print("  verify <ckpt>                      confirm a checkpoint is a live rendering main menu")
end

if mode == "capture" then
	cmdCapture(args[2] or DEFAULT_CKPT, tonumber(args[3]) or 16, tonumber(args[4]) or 540)
elseif mode == "resume" then
	cmdResume(args[2], args[3] or DEFAULT_CKPT, tonumber(args[4]) or 16, tonumber(args[5]) or 540)
elseif mode == "verify" then
	cmdVerify(args[2] or DEFAULT_CKPT)
else
	usage()
end
