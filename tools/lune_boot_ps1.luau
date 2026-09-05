local fs = require("@lune/fs")
local process = require("@lune/process")
local luneTask = require("@lune/task")
local DiscBin = require("./lib/discbin")
local Loader = require("./lib/ps1loader")

-- lune does not install a global task, but the emulator core is written for
-- the roblox engine and calls task.spawn/delay/wait.  bridge it to @lune/task.
if not task then
	task = {
		spawn = function(fn)
			return luneTask.spawn(fn)
		end,
		delay = function(seconds, fn)
			return luneTask.delay(seconds, fn)
		end,
		wait = function(seconds)
			return luneTask.wait(seconds or 0)
		end,
	}
end

local function dirname(path)
	local prefix = path:match("^(.*[\\/])")
	if prefix then
		return prefix
	end
	return ""
end

local function normalizePath(path)
	return (path:gsub("\\", "/"))
end

local function resolvePath(baseFile, childPath)
	if childPath:match("^[A-Za-z]:[\\/]") or childPath:sub(1, 1) == "/" then
		return childPath
	end
	return dirname(baseFile) .. childPath
end

local function readFileChecked(path)
	local ok, dataOrErr = pcall(function()
		return fs.readFile(path)
	end)
	if not ok then
		error(string.format("failed to read file %s: %s", path, tostring(dataOrErr)))
	end
	return dataOrErr
end

local function parseCue(cuePath)
	local cueData = readFileChecked(cuePath)
	local fileRef = cueData:match("[Ff][Ii][Ll][Ee]%s+\"([^\"]+)\"")
	if not fileRef then
		fileRef = cueData:match("[Ff][Ii][Ll][Ee]%s+([^\r\n]+)%s+[Bb][Ii][Nn][Aa][Rr][Yy]")
		if fileRef then
			fileRef = fileRef:gsub("^%s+", ""):gsub("%s+$", "")
		end
	end
	if not fileRef or fileRef == "" then
		error(string.format("could not parse BIN path from CUE: %s", cuePath))
	end

	local modeBytes = cueData:match("[Tt][Rr][Aa][Cc][Kk]%s+%d+%s+[Mm][Oo][Dd][Ee]%d/(%d+)")
	local sectorSize = tonumber(modeBytes or "")

	return {
		binPath = resolvePath(cuePath, fileRef),
		sectorSize = sectorSize,
	}
end

local function inferSectorSize(cueSectorSize, byteLength)
	if cueSectorSize == 2352 or cueSectorSize == 2048 then
		return cueSectorSize
	end
	if byteLength % 2352 == 0 then
		return 2352
	end
	if byteLength % 2048 == 0 then
		return 2048
	end
	return 2352
end

local function createDiscFromBin(binPath, hintedSectorSize)
	local binData = readFileChecked(binPath)
	local sectorSize = inferSectorSize(hintedSectorSize, #binData)
	local readSector, sectorCount = DiscBin.reader(binData, sectorSize)

	return {
		sectorSize = sectorSize,
		sectorCount = sectorCount,
		readSector = readSector,
	}
end

local MAIN_LOOP_CLUSTER_A_START = 0x80015400
local MAIN_LOOP_CLUSTER_A_STOP = 0x80015580
local MAIN_LOOP_CLUSTER_B_START = 0x80013100
local MAIN_LOOP_CLUSTER_B_STOP = 0x80013178

local function isPcInRange(pc, startAddress, stopAddress)
	if type(pc) ~= "number" then
		return false
	end
	return pc >= startAddress and pc <= stopAddress
end

local function parseArgs(args)
	local options = {
		discCue = "SLUS-0707.CUE",
		biosPath = "the-ultimate-playstation-1-bios/SCPH1001.BIN",
		seconds = 10,
		sliceInstructions = 50000,
		biosProbeSeconds = 3,
		cpuCyclesPerInstruction = 1,
		yieldBetweenChunks = false,
		yieldSleepSeconds = 0,
		forceDirectBootFallback = false,
		traceCdrom = false,
		traceBios = false,
		traceInterruptFlow = false,
		dumpFinalState = false,
	}

	local index = 1
	while index <= #args do
		local arg = args[index]
		if arg == "--disc-cue" then
			index += 1
			options.discCue = args[index]
		elseif arg == "--disc-bin" then
			index += 1
			options.discBin = args[index]
		elseif arg == "--bios" then
			index += 1
			options.biosPath = args[index]
		elseif arg == "--seconds" then
			index += 1
			options.seconds = tonumber(args[index]) or options.seconds
		elseif arg == "--slice-instructions" then
			index += 1
			options.sliceInstructions = tonumber(args[index]) or options.sliceInstructions
		elseif arg == "--bios-probe-seconds" then
			index += 1
			options.biosProbeSeconds = tonumber(args[index]) or options.biosProbeSeconds
		elseif arg == "--cpu-cycles-per-instruction" then
			index += 1
			options.cpuCyclesPerInstruction = tonumber(args[index]) or options.cpuCyclesPerInstruction
		elseif arg == "--yield-between-chunks" then
			options.yieldBetweenChunks = true
		elseif arg == "--no-yield-between-chunks" then
			options.yieldBetweenChunks = false
		elseif arg == "--yield-sleep-seconds" then
			index += 1
			options.yieldSleepSeconds = tonumber(args[index]) or options.yieldSleepSeconds
		elseif arg == "--force-direct-boot-fallback" then
			options.forceDirectBootFallback = true
		elseif arg == "--trace-cdrom" then
			options.traceCdrom = true
		elseif arg == "--trace-bios" then
			options.traceBios = true
		elseif arg == "--trace-interrupts" then
			options.traceInterruptFlow = true
		elseif arg == "--dump-final-state" then
			options.dumpFinalState = true
		elseif arg == "--help" or arg == "-h" then
			options.help = true
		else
			error("unknown argument: " .. tostring(arg))
		end
		index += 1
	end

	if not options.discCue and not options.discBin then
		error("either --disc-cue or --disc-bin must be provided")
	end

	return options
end

local function printUsage()
	print("Usage:")
	print("  lune run tools/lune_boot_ps1.luau --disc-cue SLUS-0707.CUE --bios the-ultimate-playstation-1-bios/SCPH1001.BIN --seconds 10")
	print("Options:")
	print("  --disc-cue <path>            Path to CUE file (default: SLUS-0707.CUE)")
	print("  --disc-bin <path>            Path to BIN file (override CUE parsing)")
	print("  --bios <path>                Path to BIOS ROM (default: SCPH1001 in repository)")
	print("  --seconds <n>                Wall-clock emulation duration (default: 10)")
	print("  --slice-instructions <n>     Instruction budget per run slice (default: 50000)")
	print("  --bios-probe-seconds <n>     BIOS-first probe window before fallback (default: 3)")
	print("  --cpu-cycles-per-instruction <n>  Cycles advanced per CPU step (default: 1)")
	print("  --yield-between-chunks       Yield between budget chunks (default: disabled)")
	print("  --no-yield-between-chunks    Disable chunk yields in runInstructionBudget")
	print("  --yield-sleep-seconds <n>    Sleep duration for chunk yields (default: 0)")
	print("  --force-direct-boot-fallback Always fallback to direct EXE boot if BIOS probe has no CD activity")
	print("  --trace-cdrom                Enable CD-ROM trace logging")
	print("  --trace-bios                 Enable BIOS gateway trace logging")
	print("  --trace-interrupts           Enable interrupt flow trace logging")
	print("  --dump-final-state           Dump registers and surrounding words at exit")
end

local function dumpFinalState(runtime, state)
	local registers = state.registers or {}
	print(string.format(
		"[ps1-lune] FINAL_STATE pc=%08X nextPc=%08X sp=%08X ra=%08X a0=%08X a1=%08X a2=%08X a3=%08X v0=%08X t1=%08X cause=%08X status=%08X",
		state.pc or 0,
		state.nextPc or 0,
		registers[30] or 0,
		registers[32] or 0,
		registers[5] or 0,
		registers[6] or 0,
		registers[7] or 0,
		registers[8] or 0,
		registers[3] or 0,
		registers[10] or 0,
		state.cop0 and state.cop0.cause or 0,
		state.cop0 and state.cop0.status or 0
	))

	local basePc = bit32.band((state.pc or 0) - 0x10, 0xFFFFFFFF)
	for index = 0, 8 do
		local address = bit32.band(basePc + (index * 4), 0xFFFFFFFF)
		local word = runtime.memory:read32(address)
		print(string.format("[ps1-lune] FINAL_WORD addr=%08X value=%08X", address, word))
	end

	for _, address in ipairs({ 0x80021498, 0x8002149C, 0x80022998, 0x8002299C, 0x800229A0 }) do
		print(string.format("[ps1-lune] FINAL_DATA addr=%08X value=%08X", address, runtime.memory:read32(address)))
	end
end

local function copyCounts(counts)
	return {
		status = counts and counts.status or 0,
		response = counts and counts.response or 0,
		data = counts and counts.data or 0,
		irqFlags = counts and counts.irqFlags or 0,
		irqEnable = counts and counts.irqEnable or 0,
		index = counts and counts.index or 0,
		command = counts and counts.command or 0,
		param = counts and counts.param or 0,
		irqAck = counts and counts.irqAck or 0,
		fifoControl = counts and counts.fifoControl or 0,
	}
end

local function snapshotCdromState(runtime)
	local cdromState = runtime:dumpState().cdrom or {}
	return {
		readCounts = copyCounts(cdromState.readCounts),
		writeCounts = copyCounts(cdromState.writeCounts),
		commandCount = cdromState.commandCount or 0,
		parameterByteCount = cdromState.parameterByteCount or 0,
		irqCount = cdromState.irqCount or 0,
		irqCallbackCount = cdromState.irqCallbackCount or 0,
		sectorReadCount = cdromState.sectorReadCount or 0,
	}
end

local function diffCdromState(afterState, beforeState)
	local diff = {
		readCounts = {},
		writeCounts = {},
	}
	for key, value in pairs(afterState.readCounts or {}) do
		diff.readCounts[key] = value - ((beforeState.readCounts and beforeState.readCounts[key]) or 0)
	end
	for key, value in pairs(afterState.writeCounts or {}) do
		diff.writeCounts[key] = value - ((beforeState.writeCounts and beforeState.writeCounts[key]) or 0)
	end
	diff.commandCount = (afterState.commandCount or 0) - (beforeState.commandCount or 0)
	diff.parameterByteCount = (afterState.parameterByteCount or 0) - (beforeState.parameterByteCount or 0)
	diff.irqCount = (afterState.irqCount or 0) - (beforeState.irqCount or 0)
	diff.irqCallbackCount = (afterState.irqCallbackCount or 0) - (beforeState.irqCallbackCount or 0)
	diff.sectorReadCount = (afterState.sectorReadCount or 0) - (beforeState.sectorReadCount or 0)
	return diff
end

local function runForSeconds(runtime, seconds, sliceInstructions, metrics, label)
	local startWall = os.clock()
	local nextSample = startWall

	while (os.clock() - startWall) < seconds and not runtime.cpu.halted do
		local beforePc = runtime.cpu.pc
		-- the budget is paced in runtime steps, and with the block engine each step can execute a whole trace, so count real retired instructions (cpu.instructionCount) instead of the step return value.
		local beforeIns = runtime.cpu.instructionCount or 0
		runtime:runInstructionBudget(sliceInstructions)
		metrics.executedInstructions += (runtime.cpu.instructionCount or 0) - beforeIns

		local currentPc = runtime.cpu.pc
		if currentPc ~= beforePc then
			metrics.pcStepChanges += 1
		end
		if currentPc ~= metrics.lastPc then
			metrics.pcSampleChanges += 1
			metrics.lastPc = currentPc
		end

		if label == "main" then
			if isPcInRange(currentPc, MAIN_LOOP_CLUSTER_A_START, MAIN_LOOP_CLUSTER_A_STOP) then
				metrics.mainLoopClusterASeen = true
			end
			if isPcInRange(currentPc, MAIN_LOOP_CLUSTER_B_START, MAIN_LOOP_CLUSTER_B_STOP) then
				metrics.mainLoopClusterBSeen = true
			end
		end

		local gpuStatusBit = bit32.band(runtime.memory.gpu.status or 0, 0x80000000)
		if metrics.lastGpuStatusBit ~= nil and gpuStatusBit ~= metrics.lastGpuStatusBit then
			metrics.gpuFrameFlips += 1
		end
		metrics.lastGpuStatusBit = gpuStatusBit

		local cd = runtime.memory.cdrom
		if cd and (cd.readActive == true or (cd.currentLba or 0) > 0 or #(cd.dataFifo or {}) > 0) then
			metrics.cdActivity = true
		end

		local now = os.clock()
		if now >= nextSample then
			print(string.format(
				"[ps1-lune] SAMPLE phase=%s t=%.2fs pc=%08X executed=%d lba=%d readActive=%s gpuFrameFlips=%d",
				label,
				now - metrics.startWall,
				currentPc or 0,
				metrics.executedInstructions,
				runtime.memory.cdrom.currentLba or 0,
				tostring(runtime.memory.cdrom.readActive == true),
				metrics.gpuFrameFlips
			))
			nextSample = now + 0.5
		end
	end

	metrics.wallSeconds += (os.clock() - startWall)
end

local function main()
	local options = parseArgs(process.args)
	if options.help then
		printUsage()
		return 0
	end

	if not fs.isFile(options.biosPath) then
		error("BIOS file not found: " .. tostring(options.biosPath))
	end

	local discBinPath
	local discSectorSizeHint
	if options.discBin then
		discBinPath = options.discBin
	else
		if not fs.isFile(options.discCue) then
			error("CUE file not found: " .. tostring(options.discCue))
		end
		local cue = parseCue(options.discCue)
		discBinPath = cue.binPath
		discSectorSizeHint = cue.sectorSize
	end

	if not fs.isFile(discBinPath) then
		error("BIN file not found: " .. tostring(discBinPath))
	end

	local disc = createDiscFromBin(discBinPath, discSectorSizeHint)
	local biosData = readFileChecked(options.biosPath)

	print(string.format("[ps1-lune] INPUT bios=%s (%d bytes)", normalizePath(options.biosPath), #biosData))
	print(string.format("[ps1-lune] INPUT disc=%s sectorSize=%d sectors=%d", normalizePath(discBinPath), disc.sectorSize, disc.sectorCount))

	local requirePs1 = Loader.createRequire()
	local Runtime = requirePs1("Runtime")
	local Disc = requirePs1("Disc")
	local runtime = Runtime.new({
		cpuCyclesPerInstruction = math.max(1, math.floor(options.cpuCyclesPerInstruction or 1)),
		traceStep = false,
		useBlocks = true,
		traceInterruptFlow = options.traceInterruptFlow,
		traceBios = options.traceBios,
		traceCdrom = options.traceCdrom,
		asyncSliceInstructions = options.sliceInstructions,
		asyncSliceSeconds = 0.002,
		yieldInterval = math.max(1000, math.floor(options.sliceInstructions / 2)),
		yieldBetweenChunks = options.yieldBetweenChunks,
		yieldSleepSeconds = options.yieldSleepSeconds,
	})

	runtime:mountDisc({
		readSector = disc.readSector,
	})
	-- the trace loop amortizes step re-entry on tight loops; a small budget keeps steps fine-grained so the evidence windows still sample pc per slice (the shipped runtime keeps the larger default).
	runtime.cpu._traceBudget = 256
	runtime:loadBios(biosData)
	runtime:reset(nil)
	runtime.cpu:setRegister(9, 0x1F801000)

	print("[ps1-lune] BIOS boot probe started")

	local metrics = {
		startWall = os.clock(),
		wallSeconds = 0,
		executedInstructions = 0,
		pcStepChanges = 0,
		pcSampleChanges = 0,
		lastPc = runtime.cpu.pc,
		gpuFrameFlips = 0,
		lastGpuStatusBit = bit32.band(runtime.memory.gpu.status or 0, 0x80000000),
		cdActivity = false,
		mainLoopClusterASeen = false,
		mainLoopClusterBSeen = false,
	}
	local biosProbeCdromBefore = snapshotCdromState(runtime)

	runForSeconds(runtime, options.biosProbeSeconds, options.sliceInstructions, metrics, "bios-probe")
	local biosProbeCdromAfter = runtime:dumpState().cdrom or {}
	local biosProbeCdromDelta = diffCdromState(biosProbeCdromAfter, biosProbeCdromBefore)

	local executable, loadErr = Disc.loadExecutableFromDisc(disc.readSector)
	if not executable then
		error("failed to load PS-X EXE from disc image: " .. tostring(loadErr))
	end

	local biosProbePc = runtime.cpu.pc or 0
	local biosProbeReachedRam = bit32.band(biosProbePc, 0xFFFFFFFF) < 0xBFC00000
	local fallbackTriggered = not metrics.cdActivity and (options.forceDirectBootFallback or not biosProbeReachedRam)
	if fallbackTriggered then
		print("[ps1-lune] BIOS probe showed no CD activity; applying direct executable fallback")
		runtime:loadExecutable(executable.data)
		runtime.cpu:setRegister(9, 0x1F801000)
		runtime.memory:write16(0x1F801074, bit32.bor(runtime.memory.iMask or 0, 0x0004))
	elseif not metrics.cdActivity then
		print("[ps1-lune] BIOS probe reached RAM-side execution without CD activity; keeping BIOS path")
	else
		print("[ps1-lune] BIOS probe showed CD activity; continuing BIOS path")
	end

	local header = runtime.loadedHeader
	local bootEntry = header and header.entryPoint or Disc.readU32LE(executable.data, 0x11)
	local bootLoad = header and header.loadAddress or Disc.readU32LE(executable.data, 0x19)
	local bootSize = header and header.fileSize or Disc.readU32LE(executable.data, 0x1D)
	print(string.format(
		"[ps1-lune] BOOT_EXE name=%s lba=%d bytes=%d entry=%08X load=%08X size=%08X",
		tostring(executable.name),
		executable.extentLba,
		executable.byteSize,
		bootEntry,
		bootLoad,
		bootSize
	))

	local remainingMainSeconds = math.max(0, options.seconds - metrics.wallSeconds)
	runForSeconds(runtime, remainingMainSeconds, options.sliceInstructions, metrics, "main")

	local state = runtime:dumpState()
	if options.dumpFinalState then
		dumpFinalState(runtime, state)
	end
	local biosState = state.bios or {}
	local cdromState = state.cdrom or {}
	local joypadState = state.joypad or {}
	local gatewayCallCounts = biosState.gatewayCallCounts or {}
	local hleGatewayCounts = gatewayCallCounts.hle or {}
	local padSetupCalls = hleGatewayCounts["B:5B"] or 0
	-- cd-rom probe deltas (guard chains hoisted; nil-safe).
	local cdDeltaReads = biosProbeCdromDelta.readCounts or {}
	local cdDeltaWrites = biosProbeCdromDelta.writeCounts or {}
	local padSetupEvidence = padSetupCalls > 0
	local joypadReadStatCount = joypadState.readCounts and joypadState.readCounts.stat or 0
	local joypadReadDataCount = joypadState.readCounts and joypadState.readCounts.data or 0
	local joypadWriteDataCount = joypadState.writeCounts and joypadState.writeCounts.data or 0
	local joypadWriteCtrlCount = joypadState.writeCounts and joypadState.writeCounts.ctrl or 0
	local joypadWriteModeCount = joypadState.writeCounts and joypadState.writeCounts.mode or 0
	local joypadWriteBaudCount = joypadState.writeCounts and joypadState.writeCounts.baud or 0
	local durationEvidence = metrics.wallSeconds >= (options.seconds - 0.05)
	local pcEvidence = metrics.pcSampleChanges >= 5 and metrics.pcStepChanges > 0
	local gpuEvidence = metrics.gpuFrameFlips > 0
	local bootEvidence = executable ~= nil
	local interactiveLoopEvidence = metrics.mainLoopClusterASeen and metrics.mainLoopClusterBSeen
	local biosCdromMmioEvidence = biosProbeCdromDelta.commandCount > 0
		or biosProbeCdromDelta.parameterByteCount > 0
		or (cdDeltaReads.status or 0) > 0
		or (cdDeltaReads.response or 0) > 0
		or (cdDeltaReads.irqFlags or 0) > 0
		or biosProbeCdromDelta.irqCount > 0
	local inputAcceptanceEvidence = joypadReadStatCount > 0
		and joypadReadDataCount > 0
		and joypadWriteDataCount > 0
		and joypadWriteCtrlCount > 0
		and joypadWriteModeCount > 0
		and joypadWriteBaudCount > 0

	print(string.format(
		"[ps1-lune] EVIDENCE bios_cdrom_probe statusReads=%d responseReads=%d irqFlagReads=%d commandWrites=%d paramWrites=%d irqRaises=%d irqCallbacks=%d sectorReads=%d lastCommand=%s lastIrqReason=%s",
		cdDeltaReads.status or 0,
		cdDeltaReads.response or 0,
		cdDeltaReads.irqFlags or 0,
		cdDeltaWrites.command or 0,
		cdDeltaWrites.param or 0,
		biosProbeCdromDelta.irqCount or 0,
		biosProbeCdromDelta.irqCallbackCount or 0,
		biosProbeCdromDelta.sectorReadCount or 0,
		cdromState.lastCommand and string.format("%02X", cdromState.lastCommand) or "nil",
		cdromState.lastIrqReason and string.format("%02X", cdromState.lastIrqReason) or "nil"
	))
	print(string.format(
		"[ps1-lune] EVIDENCE pad_setup gateway=B:5B calls=%d clearPad=%08X",
		padSetupCalls,
		biosState.changeClearPad or 0
	))
	print(string.format(
		"[ps1-lune] EVIDENCE interactive_loop cluster800154=%s cluster800131=%s gpuFrameFlips=%d",
		tostring(metrics.mainLoopClusterASeen),
		tostring(metrics.mainLoopClusterBSeen),
		metrics.gpuFrameFlips
	))
	print(string.format(
		"[ps1-lune] EVIDENCE joypad_mmio readStat=%d readData=%d writeData=%d ctrl=%04X mode=%04X baud=%04X lastTx=%s",
		joypadReadStatCount,
		joypadReadDataCount,
		joypadWriteDataCount,
		joypadState.ctrl or 0,
		joypadState.mode or 0,
		joypadState.baud or 0,
		joypadState.lastTxByte and string.format("%02X", joypadState.lastTxByte) or "nil"
	))
	print(string.format(
		"[ps1-lune] EVIDENCE input_acceptance joypadStatReads=%d joypadDataReads=%d joypadDataWrites=%d joypadCtrlWrites=%d joypadModeWrites=%d joypadBaudWrites=%d",
		joypadReadStatCount,
		joypadReadDataCount,
		joypadWriteDataCount,
		joypadWriteCtrlCount,
		joypadWriteModeCount,
		joypadWriteBaudCount
	))

	local passed = durationEvidence and pcEvidence and gpuEvidence and bootEvidence and padSetupEvidence and interactiveLoopEvidence and inputAcceptanceEvidence

	print(string.format(
		"[ps1-lune] RESULT status=%s wall=%.2fs executed=%d pc=%08X pcSamples=%d gpuFrameFlips=%d cdActivity=%s fallback=%s",
		passed and "PASS" or "FAIL",
		metrics.wallSeconds,
		metrics.executedInstructions,
		state.pc or 0,
		metrics.pcSampleChanges,
		metrics.gpuFrameFlips,
		tostring(metrics.cdActivity),
		tostring(fallbackTriggered)
	))

	if not passed then
		if not durationEvidence then
			print("[ps1-lune] FAIL_REASON insufficient emulation duration")
		end
		if not pcEvidence then
			print("[ps1-lune] FAIL_REASON insufficient PC advancement samples")
		end
		if not gpuEvidence then
			print("[ps1-lune] FAIL_REASON no GPU frame toggles observed")
		end
		if not bootEvidence then
			print("[ps1-lune] FAIL_REASON PS-X EXE metadata unavailable")
		end
		if not padSetupEvidence then
			print("[ps1-lune] FAIL_REASON missing HLE pad setup gateway evidence (B:5B)")
		end
		if not interactiveLoopEvidence then
			print("[ps1-lune] FAIL_REASON missing recurring post-boot main-loop PC clusters")
		end
		if not inputAcceptanceEvidence then
			print("[ps1-lune] FAIL_REASON missing controller-input acceptance evidence")
			if not biosCdromMmioEvidence then
				print(string.format(
					"[ps1-lune] BLOCKER SilentHillBiosCdromHandoff statusReads=%d responseReads=%d irqFlagReads=%d commandWrites=%d paramWrites=%d irqRaises=%d sectorReads=%d fallback=%s",
					cdDeltaReads.status or 0,
					cdDeltaReads.response or 0,
					cdDeltaReads.irqFlags or 0,
					cdDeltaWrites.command or 0,
					cdDeltaWrites.param or 0,
					biosProbeCdromDelta.irqCount or 0,
					biosProbeCdromDelta.sectorReadCount or 0,
					tostring(fallbackTriggered)
				))
			end
			print(string.format(
				"[ps1-lune] BLOCKER SilentHillInputPath fallback=%s cdActivity=%s joypadStatReads=%d joypadDataReads=%d joypadDataWrites=%d joypadCtrlWrites=%d joypadModeWrites=%d joypadBaudWrites=%d",
				tostring(fallbackTriggered),
				tostring(metrics.cdActivity),
				joypadReadStatCount,
				joypadReadDataCount,
				joypadWriteDataCount,
				joypadWriteCtrlCount,
				joypadWriteModeCount,
				joypadWriteBaudCount
			))
		end
		return 1
	end

	return 0
end

local ok, result = pcall(main)
if not ok then
	print(string.format("[ps1-lune] ERROR %s", tostring(result)))
	process.exit(1)
end

process.exit(result)