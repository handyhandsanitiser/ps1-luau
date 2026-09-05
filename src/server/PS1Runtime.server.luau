local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players      = game:GetService("Players")
local HttpService  = game:GetService("HttpService")

-- frame broadcast event for display client
local function makeRemoteEvent(name)
	local event = ReplicatedStorage:FindFirstChild(name)
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = ReplicatedStorage
	end
	return event
end
local frameEvent = makeRemoteEvent("PS1FrameEvent")

local Harness = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("Harness"))
local Util = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("Util"))
local Runtime = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("Runtime"))
local Ckpt = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("Ckpt"))
local Disc = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("Disc"))
local FrameOut = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("FrameOut"))
local Hud = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("Hud"))
local AccessTimeBase64 = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PS1"):WaitForChild("TestRoms"):WaitForChild("AccessTime"))

local RUN_CPU_TEST_ON_START = false

-- cycles per emulated instruction. must be 16: at 64 the game's pad
-- edge/click detection misses taps and input stops working.
local CPU_CYCLES_PER_INSTRUCTION = 16

local runtime = Runtime.new({
	log = function(message)
		print(message)
	end,
	cpuCyclesPerInstruction = CPU_CYCLES_PER_INSTRUCTION,
	-- the remaining trace options keep their defaults (all off); only the
	-- timing + block-cache knobs differ from the lune hosts.
	asyncSliceInstructions = 50000,
	asyncSliceSeconds = 0.01,
	-- block-cache interpreter fast path, same as tools/play.luau. without it
	-- load-state loops crawl and the session looks frozen.
	useBlocks = true,
})

-- no audio sink on this front-end, so run the spu in keep-live mode like the lune hosts: every
-- game-observable transition still runs, only the synthesis that fills the unconsumed fifo is skipped.
runtime.memory.spu.mixEnabled = false

-- pad input event: client sends the 16-bit ps1 digital pad mask.
local inputEvent = makeRemoteEvent("PS1InputEvent")

inputEvent.OnServerEvent:Connect(function(_player, mask)
	local memory = runtime and runtime.memory
	if memory and memory.joypad then
		memory.joypad.buttons = bit32.band(tonumber(mask) or 0, 0xFFFF)
	end
end)

-- frames are packed by the shared FrameOut module (rgba, little-endian w/h header) so the remoteevent payload stays small and the client can writepixelsbuffer from one buffer.
local frameLastBroadcast = 0

-- last packed vram epoch, its payload, and the status line it fired with.  an unchanged epoch means the frame is byte-identical to the last pack, so the pack + fire can be skipped (mirrors tools/play.luau).
local lastVramEpoch = -1
local lastPayload, lastPayloadW, lastPayloadH = nil, 0, 0
local lastFiredStatus = ""

-- machine state was replaced underneath the frame cache (checkpoint load,
-- runtime reset, executable boot): force the next capture to re-pack.
local function resetFrameCache()
	lastVramEpoch = -1
	lastPayload, lastPayloadW, lastPayloadH = nil, 0, 0
	lastFiredStatus = ""
end

-- hud status line, same fields as tools/play.luau: fps/steps/cpi/gs/fc/pc/buttons.
-- rebuilt once a second and sent with each frame.
local STATUS_UPDATE_INTERVAL = 1.0
local lastStatusUpdate = 0
local fpsMeter = Hud.newFpsMeter()
local currentStatus = ""

-- silent hill game-state globals live in the shared Hud module.
local function readU32Safe(memory, addr)
	if not memory then return 0 end
	local ok, v = pcall(function()
		return memory:read32(addr)
	end)
	return ok and (v or 0) or 0
end

local function buildStatus(rt, now)
	local currentFps = fpsMeter:tick(now)
	if now - lastStatusUpdate < STATUS_UPDATE_INTERVAL then
		return
	end
	lastStatusUpdate = now
	local memory = rt.memory
	local cpu = rt.cpu
	local joypad = memory and memory.joypad
	currentStatus = string.format(
		"fps=%.1f  steps=%d  cpi=%d  gs=%d  fc=%d  pc=%08X  buttons=%04X",
		currentFps,
		(cpu and cpu.instructionCount) or 0,
		CPU_CYCLES_PER_INSTRUCTION,
		readU32Safe(memory, Hud.gsAddr),
		readU32Safe(memory, Hud.fcAddr),
		(cpu and cpu.pc) or 0,
		(joypad and joypad.buttons) or 0
	)
end

-- frame capture runs inside the emulator's step call; isolate errors here so
-- a display fault can't kill the emulator thread.
local function onVBlankCapture(rt)
	-- throttle to ~10 fps so the remote channel / client rendering keep up.
	local now = os.clock()
	if now - frameLastBroadcast < 0.1 then
		return
	end
	frameLastBroadcast = now

	buildStatus(rt, now)

	local gpu = rt.memory and rt.memory.gpu
	if not gpu then return end
	local epoch = gpu._vramEpoch or 0
	local statusChanged = currentStatus ~= lastFiredStatus
	-- skip the pack + fire entirely when neither the visible frame nor the status line changed; a status-only change re-fires the cached payload.
	if epoch == lastVramEpoch and not statusChanged then
		return
	end
	local payload, w, h = lastPayload, lastPayloadW, lastPayloadH
	if epoch ~= lastVramEpoch then
		payload, w, h = FrameOut.packFrame(gpu)
		if not payload then
			return -- display not sized yet; retry at the next broadcast slot
		end
		lastPayload, lastPayloadW, lastPayloadH = payload, w, h
		lastVramEpoch = epoch
	end
	lastFiredStatus = currentStatus
	frameEvent:FireAllClients(payload, w, h, currentStatus)
end

runtime.onVBlank = function(rt)
	local ok, err = pcall(onVBlankCapture, rt)
	if not ok then
		warn(string.format("[ps1] frame capture error: %s", tostring(err)))
	end
end

local function printCpuResult(result)
	if type(result) ~= "table" then
		return
	end

	print(string.format(
		"[ps1-harness] result test=%s status=%s pc=%08X executed=%d halted=%s budget_exhausted=%s stagnant_slices=%d",
		tostring(result.testName or "cpu-test"),
		tostring(result.status or "unknown"),
		result.pc or 0,
		result.executedInstructions or 0,
		tostring(result.halted == true),
		tostring(result.budgetExhausted == true),
		result.stagnantSlices or 0
	))

	local registers = result.registers or {}
	for baseIndex = 0, 28, 4 do
		print(string.format(
			"[ps1-harness] r%02d=%08X r%02d=%08X r%02d=%08X r%02d=%08X",
			baseIndex,
			registers[baseIndex + 1] or 0,
			baseIndex + 1,
			registers[baseIndex + 2] or 0,
			baseIndex + 2,
			registers[baseIndex + 3] or 0,
			baseIndex + 3,
			registers[baseIndex + 4] or 0
		))
	end

	if result.cop0 then
		print(string.format(
			"[ps1-harness] cop0 status=%08X cause=%08X epc=%08X badvaddr=%08X prid=%08X",
			result.cop0.status or 0,
			result.cop0.cause or 0,
			result.cop0.epc or 0,
			result.cop0.badvaddr or 0,
			result.cop0.prid or 0
		))
	end
end

local function runCpuTestOnStart()
	local ok, resultOrError = pcall(function()
		return shared.PS1RunCpuTest({
			log = function(message)
				print(message)
			end,
		})
	end)

	if not ok then
		warn(string.format("[ps1-harness] error %s", tostring(resultOrError)))
		return
	end

	if type(resultOrError) == "string" then
		warn(string.format("[ps1-harness] error %s", resultOrError))
		return
	end

	printCpuResult(resultOrError)
end

shared.PS1Runtime = runtime
shared.PS1Harness = Harness
shared.PS1RunCpuTest = function(config)
	config = config or {}
	if not config.executableData then
		config.executableData = Util.decodeBase64(AccessTimeBase64)
	end
	return Harness.run(runtime, config)
end

shared.PS1RunCpuTestAndPrint = function(config)
	local result, err = shared.PS1RunCpuTest(config)
	if not result then
		warn(string.format("[ps1-harness] error %s", tostring(err)))
		return nil, err
	end
	printCpuResult(result)
	return result
end

shared.PS1LoadExecutable = function(data)
	local header = runtime:loadExecutable(data)
	runtime.cpu:setRegister(9, 0x1F801000)
	return header
end

shared.PS1MountDisc = function(disc)
	runtime:mountDisc(disc)
	print("[ps1-harness] disc mounted")
end

local DISC_SERVER_URL = "http://127.0.0.1:8080"
local BIOS_BOOT_FALLBACK_SECONDS = 8

local discSectorCaches = {}
local bootGeneration = 0
local lastBootRemoteInvoke = 0

local function getDiscCache(url)
	local cache = discSectorCaches[url]
	if not cache then
		cache = {}
		discSectorCaches[url] = cache
	end
	return cache
end

-- fetch one raw sector over http.  retry transient failures and reject payloads that don't decode to a
-- whole sector: a short body or corrupt base64 used to surface as a cryptic "failed to read volume
-- descriptor".  after the retries the warn names the exact cause (http error vs decoded byte count) so a
-- wrong server/port or stale instance answering on the url is obvious instead of a silent parse failure.
local SECTOR_FETCH_RETRIES = 3
local SECTOR_FETCH_RETRY_DELAY = 0.2

local function readRawSectorFromServer(url, cache, lba)
	if cache[lba] then
		return cache[lba]
	end

	local lastDetail
	for attempt = 1, SECTOR_FETCH_RETRIES do
		if attempt > 1 then
			task.wait(SECTOR_FETCH_RETRY_DELAY)
		end
		local okGet, data = pcall(function()
			return HttpService:GetAsync(url .. "/sector/" .. lba, true)
		end)
		if okGet and data then
			local okDecode, sector = pcall(Util.decodeBase64, data)
			if okDecode and sector and (#sector == 2352 or #sector == 2048) then
				cache[lba] = sector
				return sector
			end
			lastDetail = string.format(
				"bad body: http returned %d chars; %s",
				#data,
				okDecode and ("decoded to " .. tostring(#(sector or "")) .. " bytes (want 2352)") or ("decode error: " .. tostring(sector))
			)
		else
			lastDetail = "http error: " .. tostring(data)
		end
	end

	-- warn once per sector so a fully failing session doesn't flood the output
	local warned = cache["_sectorWarned"] or {}
	cache["_sectorWarned"] = warned
	if not warned[lba] then
		warned[lba] = true
		warn(string.format(
			"[ps1] disc sector %d fetch failed after %d tries: %s",
			lba,
			SECTOR_FETCH_RETRIES,
			tostring(lastDetail)
		))
	end
	return nil
end

-- host transport: the roblox front-end fetches raw sectors over http from disc_server.py through a per-url cache; everything above the transport lives in the shared Disc module.
local function loadExecutableFromDiscImage(url)
	local cache = getDiscCache(url)
	return Disc.loadExecutableFromDisc(function(lba)
		return readRawSectorFromServer(url, cache, lba)
	end)
end

shared.PS1LoadBios = function(url)
	url = url or DISC_SERVER_URL
	print("[ps1] loading BIOS from " .. url .. "/bios")
	local ok, resp = pcall(function()
		return HttpService:GetAsync(url .. "/bios", true)
	end)
	if not ok then
		warn("[ps1] BIOS load failed: " .. tostring(resp))
		return false
	end
	local biosData = Util.decodeBase64(resp)
	runtime:loadBios(biosData)
	print(string.format("[ps1] BIOS loaded: %d bytes", #biosData))
	return true
end

shared.PS1LoadDisc = function(url)
	url = url or DISC_SERVER_URL
	print("[ps1] connecting to disc server: " .. url)
	local ok, countResp = pcall(function()
		return HttpService:GetAsync(url .. "/info", true)
	end)
	if not ok then
		warn("[ps1] disc server unreachable: " .. tostring(countResp))
		warn("[ps1] make sure disc_server.py is running:  python disc_server.py <path/to/disc.bin>")
		return false
	end
	local sectorCount = tonumber(countResp) or 0
	local cache = getDiscCache(url)
	runtime:mountDisc({
		readSector = function(lba)
			return readRawSectorFromServer(url, cache, lba)
		end,
	})
	print(string.format("[ps1] disc mounted: %d sectors", sectorCount))
	return true
end

-- resume the highest sh_gs_n.bin instead of cold-booting; this front-end calls it only when the
-- boot explicitly asked for resume (cold boot is the default).  disc_server.py serves the checkpoints
-- directory (roblox can't read local files); the disc must be mounted first and the bios loaded.

shared.PS1ResumeCheckpoint = function(url)
	url = url or DISC_SERVER_URL
	local okChecks, list = pcall(function()
		return HttpService:GetAsync(url .. "/checkpoints", true)
	end)
	if not okChecks then
		print("[ps1] /checkpoints unavailable (" .. tostring(list) .. "); cold boot")
		return false, "checkpoint list unavailable"
	end

	local candidates = {}
	for name in string.gmatch(list or "", "[^\r\n]+") do
		local gs = tonumber(name:match("^sh_gs_(%d+)%.bin$"))
		if gs then
			candidates[#candidates + 1] = { name = name, gs = gs }
		end
	end
	table.sort(candidates, function(a, b) return a.gs > b.gs end)
	if #candidates == 0 then
		print("[ps1] no sh_gs_N.bin checkpoints on the disc server; cold boot")
		return false, "no checkpoints available"
	end

	for _, cand in ipairs(candidates) do
		local okData, b64 = pcall(function()
			return HttpService:GetAsync(string.format("%s/checkpoint/%s", url, cand.name), true)
		end)
		if not okData then
			warn(string.format("[ps1] checkpoint %s fetch failed: %s", cand.name, tostring(b64)))
		elseif okData and b64 then
			local okLoad, loadErr = pcall(function()
				Ckpt.loadData(runtime, Util.decodeBase64(b64))
			end)
			if okLoad then
				print(string.format("[ps1] resumed checkpoint %s (gs=%d) pc=%08X", cand.name, cand.gs, runtime.cpu.pc or 0))
				resetFrameCache() -- checkpoint restored the machine; re-pack the first frame
				runtime:runAsync()
				return true, "checkpoint resume: " .. cand.name
			end
			warn(string.format("[ps1] checkpoint %s failed to load: %s", cand.name, tostring(loadErr)))
		end
	end
	print("[ps1] no usable checkpoint; cold boot")
	return false, "checkpoints failed to load"
end

shared.PS1BootExecutableFromDisc = function(url)
	url = url or DISC_SERVER_URL
	bootGeneration += 1
	local executable, err = loadExecutableFromDiscImage(url)
	if not executable then
		warn("[ps1] direct executable boot failed: " .. tostring(err))
		return false, tostring(err)
	end

	local header = runtime:loadExecutable(executable.data)
	runtime.cpu:setRegister(9, 0x1F801000)
	runtime.memory:write16(0x1F801074, bit32.bor(runtime.memory.iMask or 0, 0x0004))
	resetFrameCache() -- new executable state; re-pack the first frame
	print(string.format(
		"[ps1] direct boot executable: %s lba=%d bytes=%d entry=%08X load=%08X size=%08X",
		tostring(executable.name),
		executable.extentLba,
		executable.byteSize,
		header and header.entryPoint or 0,
		header and header.loadAddress or 0,
		header and header.fileSize or 0
	))
	runtime:runAsync()
	return true
end

shared.PS1Boot = function(entryPoint)
	runtime:reset(entryPoint)
	resetFrameCache() -- fresh machine state; re-pack the first frame
	-- bios reset code expects $t1 to point at the memory-control block.
	runtime.cpu:setRegister(9, 0x1F801000)
	print(string.format("[ps1] booting from %08X", entryPoint or 0xBFC00000))
	runtime:runAsync()
end

shared.PS1Stop = function()
	runtime:stopAsync()
	print("[ps1] stopped")
end

shared.PS1Capabilities = function()
	return runtime:getCapabilityReport()
end

shared.PS1BootFromDisc = function(url, resume)
	url = url or DISC_SERVER_URL
	bootGeneration += 1
	local myGeneration = bootGeneration
	runtime:stopAsync()
	if not shared.PS1LoadDisc(url) then
		warn("[ps1] cannot boot: disc load failed")
		return false, "disc load failed"
	end

	-- cold boot by default; checkpoint resume only runs when resume == true.  (bios must be in
	-- memory before loaddata because the checkpoint records biosloaded=1.)
	local biosLoaded = shared.PS1LoadBios(url)
	if resume then
		local resumedOk, resumeDetail = shared.PS1ResumeCheckpoint(url)
		if resumedOk then
			return true, resumeDetail
		end
		print("[ps1] " .. tostring(resumeDetail))
	else
		print("[ps1] checkpoint resume disabled for this boot; cold booting from disc")
	end
	if biosLoaded then
		print("[ps1] BIOS loaded; starting BIOS-first disc boot")
		shared.PS1Boot()
		task.delay(BIOS_BOOT_FALLBACK_SECONDS, function()
			if myGeneration ~= bootGeneration then
				return
			end

			local cd = runtime.memory and runtime.memory.cdrom or nil
			if not cd then
				return
			end

			local noCdProgress = cd.readActive ~= true
				and (cd.currentLba or 0) == 0
				and (cd.targetLba or 0) == 0
				and #(cd.dataFifo or {}) == 0

			if runtime.biosLoaded and noCdProgress then
				warn("[ps1] BIOS boot appears stalled (no CD activity); falling back to direct executable boot")
				runtime:stopAsync()
				local bootedExecutable, bootErr = shared.PS1BootExecutableFromDisc(url)
				if not bootedExecutable then
					warn("[ps1] fallback direct executable boot failed: " .. tostring(bootErr))
				end
			end
		end)
		return true, "bios boot"
	end

	warn("[ps1] BIOS load failed; falling back to direct executable boot")
	local bootedExecutable, bootErr = shared.PS1BootExecutableFromDisc(url)
	if bootedExecutable then
		return true, "direct executable boot fallback"
	end

	return false, "bios load failed and direct executable boot failed: " .. tostring(bootErr)
end

local function makeRemoteFunction(name, handler)
	local rf = ReplicatedStorage:FindFirstChild(name)
	if not rf then
		rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = ReplicatedStorage
	end
	rf.OnServerInvoke = handler
	return rf
end

makeRemoteFunction("PS1RunCpuTestRemote", function(_, config)
	local ok, resultOrError = pcall(function()
		return shared.PS1RunCpuTestAndPrint(config)
	end)

	if not ok then
		return nil, tostring(resultOrError)
	end

	if not resultOrError then
		return nil, "cpu test returned nil result"
	end

	return resultOrError, nil
end)

makeRemoteFunction("PS1BiosBootRemote", function(_, url)
	-- boot bios-first: let the real bios rom initialise the machine then load the game.
	url = url or DISC_SERVER_URL
	local ok, err = pcall(function()
		runtime:stopAsync()
		if not shared.PS1LoadDisc(url) then error("disc load failed") end
		if not shared.PS1LoadBios(url) then error("bios load failed") end
		runtime:reset(nil)  -- reset to BFC00000 with BEV=1
		resetFrameCache()
		runtime:runAsync()
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, "bios boot started"
end)

makeRemoteFunction("PS1BootFromDiscRemote", function(_, url, resume)
	local now = os.clock()
	if now - lastBootRemoteInvoke < 1.0 then
		return true, "boot request ignored (debounced)"
	end
	lastBootRemoteInvoke = now

	local ok, booted, detail = pcall(function()
		return shared.PS1BootFromDisc(url, resume)
	end)
	if not ok then
		return false, tostring(booted)
	end
	if not booted then
		return false, tostring(detail or "boot failed")
	end
	return true, detail or "booting"
end)

makeRemoteFunction("PS1StopRemote", function(_)
	shared.PS1Stop()
	return true
end)

makeRemoteFunction("PS1LoadDiscRemote", function(_, url)
	return shared.PS1LoadDisc(url)
end)

makeRemoteFunction("PS1LoadBiosRemote", function(_, url)
	return shared.PS1LoadBios(url)
end)

makeRemoteFunction("PS1StateRemote", function(_)
	local cpu = runtime.cpu
	local memory = runtime.memory
	local cdrom = memory and memory.cdrom or nil
	local pc = cpu and cpu.pc or 0
	local epc = cpu and cpu.cop0 and cpu.cop0.epc or 0
	local function readWord(addr)
		if not memory then
			return 0
		end
		return memory:read32(addr)
	end
	-- nine words centered on pc, stepping 4 bytes, wrapping addresses like a real pc window.
	local function readWindow(pc, halfWidth)
		local window = {}
		for offset = -halfWidth, halfWidth do
			window[#window + 1] = readWord(bit32.band(pc + offset * 4, 0xFFFFFFFF))
		end
		return window
	end
	-- words at the probe addresses passed as varargs.
	local function readProbe(...)
		local words = {}
		for i = 1, select("#", ...) do
			words[i] = readWord((select(i, ...)))
		end
		return words
	end
	return {
		pc = pc,
		nextPc = cpu and cpu.nextPc or 0,
		epc = epc,
		cause = cpu and cpu.cop0 and cpu.cop0.cause or 0,
		status = cpu and cpu.cop0 and cpu.cop0.status or 0,
		pcInstr = readWord(pc),
		epcInstr = readWord(epc),
		instrWindow = readWindow(pc, 4),
		probe10000 = readProbe(0x80010000, 0x80010004, 0x80010008, 0x8001000C),
		probeEntry = readProbe(0x80012F7C, 0x80012F80, 0x80012F84, 0x80012F88),
		probeBios = readProbe(0xBFC00000, 0xBFC00004, 0xBFC00180, 0xBFC00184, 0xBFC00188, 0xBFC0018C),
		at = cpu and cpu:getRegister(1) or 0,
		ra = cpu and cpu:getRegister(31) or 0,
		sp = cpu and cpu:getRegister(29) or 0,
		a0 = cpu and cpu:getRegister(4) or 0,
		a1 = cpu and cpu:getRegister(5) or 0,
		a2 = cpu and cpu:getRegister(6) or 0,
		a3 = cpu and cpu:getRegister(7) or 0,
		v0 = cpu and cpu:getRegister(2) or 0,
		v1 = cpu and cpu:getRegister(3) or 0,
		t0 = cpu and cpu:getRegister(8) or 0,
		t1 = cpu and cpu:getRegister(9) or 0,
		t2 = cpu and cpu:getRegister(10) or 0,
		t3 = cpu and cpu:getRegister(11) or 0,
		t4 = cpu and cpu:getRegister(12) or 0,
		t5 = cpu and cpu:getRegister(13) or 0,
		t6 = cpu and cpu:getRegister(14) or 0,
		t9 = cpu and cpu:getRegister(25) or 0,
		iStat = memory and memory.iStat or 0,
		iMask = memory and memory.iMask or 0,
		pending = memory and memory:getPendingInterruptMask() or 0,
		cd = {
			readActive = cdrom and cdrom.readActive == true or false,
			currentLba = cdrom and cdrom.currentLba or 0,
			targetLba = cdrom and cdrom.targetLba or 0,
			irqFlags = cdrom and cdrom.irqFlags or 0,
			irqEnable = cdrom and cdrom.irqEnable or 0,
			dataFifo = cdrom and #cdrom.dataFifo or 0,
			responseFifo = cdrom and #cdrom.responseFifo or 0,
			paramFifo = cdrom and #cdrom.paramFifo or 0,
		},
	}
end)

makeRemoteFunction("PS1CapabilitiesRemote", function(_)
	return shared.PS1Capabilities()
end)

print("PS1 runtime initialized")

if RUN_CPU_TEST_ON_START then
	runCpuTestOnStart()
else
	print("[ps1-harness] startup test disabled for fast launch; server console: shared.PS1RunCpuTestAndPrint()")
	print("[ps1-harness] to boot a real disc: start disc_server.py then run from client command bar:")
	print("[ps1-harness]   game:GetService('ReplicatedStorage'):WaitForChild('PS1BootFromDiscRemote'):InvokeServer()")
	print("[ps1-harness] cpu test via client: game:GetService('ReplicatedStorage'):WaitForChild('PS1RunCpuTestRemote'):InvokeServer()")
end

-- pressing play in studio should just work: wait until tools/disc_server.py answers on disc_server_url, then boot the disc.  requires httpservice enabled and studio loopback http.
local autoBooted = false
local autoBootAttempts = 0
local function tryAutoBoot()
	if autoBooted then return end
	autoBootAttempts += 1
	if autoBootAttempts > 200 then
		warn("[ps1] gave up waiting for the disc server; invoke PS1BootFromDiscRemote manually")
		return
	end
	local ok, info = pcall(function()
		return HttpService:GetAsync(DISC_SERVER_URL .. "/health", true)
	end)
	if not ok then
		print(string.format("[ps1] disc server not reachable yet (attempt %d): %s", autoBootAttempts, tostring(info)))
		print("[ps1] start it with:  python tools/disc_server.py SLUS-0707.BIN --bios the-ultimate-playstation-1-bios/SCPH1001.BIN")
		task.delay(3, tryAutoBoot)
		return
	end
	autoBooted = true
	print("[ps1] disc server reachable - auto-booting")
	local bootOk, bootDetail = pcall(function()
		return shared.PS1BootFromDisc(DISC_SERVER_URL)
	end)
	if not bootOk then
		warn("[ps1] auto-boot failed: " .. tostring(bootDetail))
		autoBooted = false
		task.delay(5, tryAutoBoot)
	end
end

task.delay(1.0, tryAutoBoot)