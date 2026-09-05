-- interactive ps1 front-end: starts a small http/websocket server and streams the software
-- framebuffer to a browser.  `menu` resumes the local checkpoint, `clean` starts at the bios reset
-- vector; cpi 16 is the conservative speed/accuracy setting, 64 for exploring a saved state.
--   lune run tools/play.luau [port] [checkpoint] [cpi] [mix]
local net = require("@lune/net")
local task = require("@lune/task")
local process = require("@lune/process")
local Loader = require("./lib/ps1loader")
local requirePs1 = Loader.createRequire()
local FrameOut = requirePs1("FrameOut")
local Hud = requirePs1("Hud")
local band = bit32.band
local rshift = bit32.rshift

local args = process.args or {}
local port = tonumber(args[1]) or 8890
local ckptArg = args[2] or "menu" -- default: Silent Hill main menu (renders with input)
local cpi = tonumber(args[3]) or 64
local mixEnabled = args[4] == "1"

local checkpoint
if ckptArg == "clean" then
	checkpoint = nil
elseif ckptArg == "menu" then
	checkpoint = "checkpoints/sh_gs_7.bin"
else
	checkpoint = ckptArg
end

-- boot configuration is shared between the initial run and /cmd?restart=1 reloads.
local bootOptions = {
	cpuCyclesPerInstruction = cpi,
	yieldInterval = 1000000,
	yieldBetweenChunks = false,
	yieldSleepSeconds = 0,
	traceCdrom = false,
	traceVBlank = false,
	useBlocks = true,
	checkpoint = checkpoint,
}
local _boot = require("./lib/boot").boot(bootOptions)
local runtime = _boot.runtime
local mem = _boot.mem
runtime:reapplyConsoleRegion()
mem.spu.mixEnabled = mixEnabled
local gpu = mem.gpu
local timers = mem.timers

-- game-state globals used by the silent hill debug probes (shared map).
local gsAddr = Hud.gsAddr
local fcAddr = Hud.fcAddr
local MENU_STATE = 0x800A9A74
local MENU_SEL = 0x800A9A78
local DEMO_COUNT = 0x800A9A80
local CTRL0_PTR = 0x80024D4C
local RC = 0x800BCCDC -- game raw-controller struct (probe-injected at InGame)
local function u32(a) return mem:read32(a) or 0 end
local function readGs() return u32(gsAddr) end
local function ctrlFlags(off)
	local ptr = u32(CTRL0_PTR) or 0
	if ptr == 0 then return 0 end
	return u32(ptr + off) or 0
end

-- shared state between the emulator loop and the http handlers.
local state = {
	-- latest captured frame (rgb15 bytes, header-prefixed; w/h ride in the header)
	frame = nil,
	-- input: 16-bit ps1 pad mask, set bits = pressed
	inputMask = 0,
	-- status counters
	fps = 0,
	startWall = os.clock(),
	lastStatus = "",
	restartRequested = false,
}

-- pack the framebuffer in rgb15 (the browser canvas decodes 2-byte rgb15 cheaply in js): ~40% less
-- pack cost and half the payload vs the rgba mode the roblox front-end still uses.
local function captureFrameBytes()
	return FrameOut.packFrame(gpu, true)
end

-- restart support (re-load the checkpoint / boot fresh).
local function doRestart()
	-- re-create from the same boot options: rebuild the whole runtime so the
	-- restart is a true clean state (matches the launch configuration).
	local boot2 = require("./lib/boot").boot(bootOptions)
	runtime = boot2.runtime
	mem = boot2.mem
	runtime:reapplyConsoleRegion()
	mem.spu.mixEnabled = mixEnabled
	gpu = mem.gpu
	timers = mem.timers
	state.inputMask = 0
	state.restartRequested = false
end

-- http server
local PAGE = [[<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>PS1 — Silent Hill (Luau emulator)</title>
<style>
  html, body { margin:0; padding:0; background:#000; height:100%; overflow:hidden; }
  #wrap { display:flex; flex-direction:column; align-items:center; justify-content:center; height:100%; }
  canvas { image-rendering:pixelated; image-rendering:crisp-edges; background:#000; max-width:96vw; max-height:88vh; }
  # hud { color:#9f9; font:12px monospace; margin-top:6px; white-space:pre; text-align:center; }
  # hint { color:#666; font:11px monospace; margin-top:2px; text-align:center; }
</style>
</head>
<body>
<div id="wrap">
  <canvas id="scr"></canvas>
  <div id="hud">connecting…</div>
  <div id="hint">D-pad: arrows/WASD · Cross: X · Circle: C · Triangle: T · Square: V · Start: Enter · Select: Backspace · L1/R1: Q/E · L2/R2: 1/3</div>
</div>
<script>
const canvas = document.getElementById('scr');
const ctx = canvas.getContext('2d');
ctx.imageSmoothingEnabled = false;
let img = null;

// ps1 digital pad mask (set bit = pressed)
const MAP = {
  'arrowup': 0x0010, 'w': 0x0010,
  'arrowdown': 0x0040, 's': 0x0040,
  'arrowleft': 0x0080, 'a': 0x0080,
  'arrowright': 0x0020, 'd': 0x0020,
  'x': 0x4000, 'j': 0x4000, 'k': 0x4000,   // Cross
  'c': 0x2000, 'l': 0x2000,               // Circle
  't': 0x1000, 'y': 0x1000,               // Triangle
  'v': 0x8000, 'u': 0x8000,               // Square
  'enter': 0x0008,                        // Start
  'backspace': 0x0001,                    // Select
  'q': 0x0400, 'e': 0x0800,               // L1 R1
  '1': 0x0100, '3': 0x0200,               // L2 R2
};
const held = {};
function mask() {
  let m = 0;
  for (const k in held) if (held[k] && MAP[k]) m |= MAP[k];
  return m;
}
let lastSent = -1;
function sendInput() {
  const m = mask();
  if (m === lastSent) return;
  lastSent = m;
  fetch('/input', { method: 'POST', body: String(m) }).catch(()=>{});
}
window.addEventListener('keydown', e => {
  const k = e.key.toLowerCase();
  if (MAP[k]) { e.preventDefault(); }
  if (!held[k]) { held[k] = true; sendInput(); }
});
window.addEventListener('keyup', e => {
  const k = e.key.toLowerCase();
  if (held[k]) { held[k] = false; sendInput(); }
});
window.addEventListener('blur', () => {
  for (const k in held) held[k] = false;
  sendInput();
});

// ---- frame delivery ------------------------------------------------------
// rgb15 wire format: 8-byte le w/h header + w*h*2 bytes of 15-bit color.
// decode to rgba8 for the canvas here: jit-side work that halves the wire
// payload and saves the server roughly 40% of the pack cost per changed
// frame (the packed 573kb rgba blob of the old format is gone).
function drawFrame(buf) {
  try {
    const dv = new DataView(buf);
    const w = dv.getUint32(0, true), h = dv.getUint32(4, true);
    if (!w || !h) return;
    if (!img || img.width !== w || img.height !== h) {
      img = ctx.createImageData(w, h);
      canvas.width = w * 2; canvas.height = h * 2;
    }
    const src = new Uint8ClampedArray(buf, 8);
    const px = img.data;
    for (let i = 0, o = 0; i < src.length; i += 2) {
      const p = src[i] | (src[i + 1] << 8);
      px[o++] = (p & 0x1F) * 8;
      px[o++] = ((p >> 5) & 0x1F) * 8;
      px[o++] = ((p >> 10) & 0x1F) * 8;
      px[o++] = 255;
    }
    ctx.putImageData(img, 0, 0);
    ctx.drawImage(canvas, 0, 0, canvas.width, canvas.height);
  } catch (e) { /* ignore malformed frame */ }
}
// primary: the server pushes each frame over a websocket. message events are
// not throttled when the tab is unfocused/hidden (unlike timers), so the
// canvas updates in real time everywhere, including embedded previews.
// fallback: http polling on a plain timer, used until the socket connects
// and re-used if the socket ever drops.
let poller = null;
let wsLive = false;
function startPoller() {
  if (poller) return;
  let inflight = false;
  const poll = () => {
    if (inflight) return;
    inflight = true;
    fetch('/frame').then(r => r.arrayBuffer()).then(b => { inflight = false; drawFrame(b); })
      .catch(() => { inflight = false; });
    setTimeout(poll, 66);
  };
  poller = poll;
  poll();
}
function stopPoller() { poller = null; }
function connectWS() {
  let ws;
  try { ws = new WebSocket('ws://' + location.host); }
  catch (e) { startPoller(); return; }
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => { wsLive = true; stopPoller(); };
  ws.onmessage = (e) => { if (typeof e.data !== 'string') drawFrame(e.data); };
  ws.onerror = () => { /* close handler follows */ };
  ws.onclose = () => {
    wsLive = false;
    if (!poller) startPoller();
    setTimeout(() => { if (!wsLive) connectWS(); }, 2000);
  };
}
connectWS();

function pollStatus() {
  fetch('/status').then(r => r.text()).then(t => {
    document.getElementById('hud').textContent = t;
  }).catch(()=>{});
  setTimeout(pollStatus, 1000);
}
setTimeout(pollStatus, 500);
</script>
</body>
</html>]]

local function handleRequest(req)
	local path = req.path or "/"
	if path == "/" or path == "/index.html" then
		return { status = 200, headers = { ["Content-Type"] = "text/html; charset=utf-8" }, body = PAGE }
	elseif path == "/frame" then
		if state.frame then
			return { status = 200, headers = { ["Content-Type"] = "application/octet-stream" }, body = state.frame }
		end
		return { status = 204, body = "" }
	elseif path == "/input" then
		local m = tonumber(req.body or "")
		if m then
			state.inputMask = band(m, 0xFFFF)
		end
		return { status = 200, body = "ok" }
	elseif path == "/status" then
		return { status = 200, headers = { ["Content-Type"] = "text/plain; charset=utf-8" }, body = state.lastStatus }
	elseif path == "/cmd" then
		if (req.query or {}).restart == "1" then
			state.restartRequested = true
		end
		return { status = 200, body = "ok" }
	end
	return { status = 404, body = "not found" }
end

-- websocket frame push: every connected browser gets each captured frame; binary messages aren't throttled by tab visibility, so unfocused tabs stay live.
local wsClients = {}

local function broadcastFrame(frame)
	if frame == nil then return end
	for i = #wsClients, 1, -1 do
		local ws = wsClients[i]
		local ok, err = pcall(function()
			ws:send(frame, true) -- asBinaryMessage
		end)
		if not ok then
			table.remove(wsClients, i)
		end
	end
end

local server = net.serve(port, {
	handleRequest = handleRequest,
	handleWebSocket = function(ws)
		wsClients[#wsClients + 1] = ws
		while true do
			local msg = ws:next()
			if not msg then break end
		end
		for i = #wsClients, 1, -1 do
			if wsClients[i] == ws then table.remove(wsClients, i) end
		end
	end,
})
print(string.format("[play] PS1 emulator front-end on http://127.0.0.1:%d  (cpi=%d mix=%d ckpt=%s)",
	port, cpi, mixEnabled and 1 or 0, tostring(checkpoint)))

-- emulator main loop: run one emulated frame, apply input, capture output.
local steps = 0
local wallStart = os.clock()
local fpsMeter = Hud.newFpsMeter()
local lastTick = timers.vblankTick or 0
-- last gpu vram epoch we packed: the gpu bumps _vramEpoch on every gp0/gp1 word, so an unchanged epoch means the frame is identical to the last pack and the pack + push can be skipped (-1 forces the first frame).
local lastVramEpoch = -1
-- yield to the http server only every few frames: task.wait(0) costs ~16ms here, so per-frame waits would cap emulation near ~50 fps; batching bounds input latency to FRAMES_PER_YIELD frames.
local FRAMES_PER_YIELD = 4
local framesSinceYield = 0

while true do
	-- run until the next vblank (one emulated frame).
	local target = lastTick + 1
	while (timers.vblankTick or 0) < target do
		if not runtime:step() then
			-- cpu halted; keep serving status so the ui shows it.
			task.wait(0.05)
			break
		end
		steps += 1
	end
	lastTick = timers.vblankTick or target

	-- apply the latest browser input to the pad.
	mem.joypad.buttons = state.inputMask

	-- capture + push only when the gpu may have changed the visible frame since the last pack; the fps meter ticks per emulated frame regardless, so it still reports speed while the display is idle.
	local now = os.clock()
	state.fps = fpsMeter:tick(now)
	if (gpu._vramEpoch or 0) ~= lastVramEpoch then
		state.frame = captureFrameBytes()
		broadcastFrame(state.frame)
		lastVramEpoch = gpu._vramEpoch or 0
	end

	-- status line (updated once per second of wall time).
	if now - wallStart >= 1.0 then
		wallStart = now
		state.lastStatus = string.format(
			"fps=%.1f  steps=%d  cpi=%d  gs=%d  fc=%d  ms=%d demo=%d held=%04X click=%04X padRd=%d rc=%04X  pc=%08X  buttons=%04X",
			state.fps, steps, cpi, readGs(), u32(fcAddr), u32(MENU_STATE), u32(DEMO_COUNT), ctrlFlags(0x0C), ctrlFlags(0x10), mem.joypad.readCounts.data or 0, band(u32(RC + 2) or 0, 0xFFFF), runtime.cpu.pc or 0, state.inputMask)
	end

	if state.restartRequested then
		doRestart()
		lastTick = timers.vblankTick or 0
		lastVramEpoch = -1 -- fresh gpu starts at epoch 0; force the first pack
	end

	-- yield so the http server can process browser requests.
	framesSinceYield += 1
	if framesSinceYield >= FRAMES_PER_YIELD then
		framesSinceYield = 0
		task.wait(0)
	end
end
