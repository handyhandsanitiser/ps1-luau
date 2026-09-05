-- shared bootstrap for the maintained lune frontends: mounts the local disc and bios on a Runtime
-- from src/shared/PS1.  the module loader itself lives in tools/lib/ps1loader.luau so every host
-- resolves the emulator the same way.
local fs = require("@lune/fs")
local DiscBin = require("./discbin")
local Loader = require("./ps1loader")

local requirePs1 = Loader.createRequire()
local Runtime = requirePs1("Runtime")

local Boot = {}

-- step until vblankTick has advanced `frames` vblanks, with a step guard against
-- a stalled clock.  returns "ok" | "halted" | "guard" so callers keep their own
-- diagnostics.  the same pacing the interactive front-ends use.
function Boot.runFrames(runtime, frames, stepGuard)
	local timers = runtime.memory.timers
	local target = (timers.vblankTick or 0) + frames
	local guard = 0
	while (timers.vblankTick or 0) < target do
		if not runtime:step() then
			return "halted"
		end
		guard += 1
		if guard > stepGuard then
			return "guard"
		end
	end
	return "ok"
end

-- - Create a Runtime with the local disc and BIOS mounted, optionally restoring
-- - a checkpoint. Returns the objects used by the Lune frontends.
function Boot.boot(options)
	options = options or {}
	local runtime = Runtime.new({
		cpuCyclesPerInstruction = options.cpuCyclesPerInstruction or 16,
		yieldInterval = options.yieldInterval or 1000000,
		yieldBetweenChunks = options.yieldBetweenChunks == true,
		yieldSleepSeconds = options.yieldSleepSeconds or 0,
		traceCdrom = options.traceCdrom == true,
		traceVBlank = options.traceVBlank == true,
		traceInterruptFlow = options.traceInterruptFlow == true,
		-- the block cache is the default for interactive runs; instruction-level
		-- probes can explicitly disable it.
		useBlocks = options.useBlocks ~= false,
		-- console region override ("ntsc"|"pal"); nil = auto-detect from bios.
		consoleRegion = options.consoleRegion,
	})
	-- keep spu state live for headless runs, but avoid mixing when there is no
	-- audio consumer. checkpoint loading does not serialize this host setting.
	runtime.memory.spu.mixEnabled = options.synthesis == true
	local binData = fs.readFile(options.discPath or "SLUS-0707.BIN")
	local readSector = DiscBin.reader(binData, 2352)
	runtime:mountDisc({ readSector = readSector })
	runtime:loadBios(fs.readFile(options.biosPath or "the-ultimate-playstation-1-bios/SCPH1001.BIN"))
	if options.checkpoint then
		requirePs1("Ckpt").load(runtime, options.checkpoint, fs.readFile)
		-- the checkpoint persists the gpu frame period; the console region
		-- (from the bios/override) is authoritative and wins over the save.
		runtime:reapplyConsoleRegion()
	end
	local mem = runtime.memory
	local cpu = runtime.cpu
	cpu.traceExceptions = false
	mem.traceInterruptRegisters = false
	if options.buttons ~= nil then
		mem.joypad.buttons = options.buttons
	end
	return {
		runtime = runtime,
		mem = mem,
		cpu = cpu,
		readSector = readSector,
		ckpt = requirePs1("Ckpt"),
		u32 = function(addr) return mem:read32(addr) or 0 end,
		runFrames = Boot.runFrames,
	}
end

return Boot
