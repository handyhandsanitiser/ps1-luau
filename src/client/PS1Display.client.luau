local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService     = game:GetService("AssetService")
local UserInputService = game:GetService("UserInputService")

local function invokeRemote(name, ...)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(name, 10)
	end
	if not remote then
		return false, string.format("missing remote: %s", name)
	end

	local args = table.pack(...)
	local ok, a, b = pcall(function()
		return remote:InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok then
		return false, tostring(a)
	end

	if a == false then
		return false, tostring(b or "request failed")
	end

	return true, b or a
end

-- convenience client helpers so command bar calls work in play mode.  boots cold by default;
-- pass resume=true to load the newest sh_gs_n.bin checkpoint from the disc server instead.
shared.PS1BootFromDisc = function(url, resume)
	local ok, detail = invokeRemote("PS1BootFromDiscRemote", url, resume)
	if not ok then
		warn("[ps1-client] boot failed: " .. tostring(detail))
		return false, detail
	end
	print("[ps1-client] booting: " .. tostring(detail))
	return true, detail
end

shared.PS1Stop = function()
	local ok, detail = invokeRemote("PS1StopRemote")
	if not ok then
		warn("[ps1-client] stop failed: " .. tostring(detail))
		return false, detail
	end
	return true, detail
end

local player    = Players.LocalPlayer or Players.PlayerAdded:Wait()
local playerGui = player:WaitForChild("PlayerGui")

-- wait for server frame event
local frameEvent = ReplicatedStorage:WaitForChild("PS1FrameEvent", 30)

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PS1Display"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromScale(1, 1)
frame.BackgroundColor3 = Color3.fromRGB(7, 8, 11)
frame.BorderSizePixel = 0
frame.Parent = screenGui

local label = Instance.new("ImageLabel")
label.AnchorPoint = Vector2.new(0.5, 0.5)
label.Position = UDim2.fromScale(0.5, 0.48)
label.Size = UDim2.new(1, -32, 1, -64)
label.BackgroundTransparency = 1
label.ScaleType = Enum.ScaleType.Fit
label.Parent = frame

local statusLabel = Instance.new("TextLabel")
statusLabel.AnchorPoint = Vector2.new(0.5, 1)
statusLabel.Position = UDim2.new(0.5, 0, 1, -12)
statusLabel.Size = UDim2.new(1, -32, 0, 20)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Code
statusLabel.TextColor3 = Color3.fromRGB(160, 171, 190)
statusLabel.TextSize = 13
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Text = "PS1  ·  waiting for the first frame"
statusLabel.Parent = frame

if not frameEvent then
	statusLabel.Text = "PS1  ·  display event unavailable; check the server script"
	return
end

local currentImage = nil
local lastW, lastH = 0, 0
local frameCount = 0

-- detect which write api this roblox version exposes
local function writePixelsToImage(img, w, h, buf)
	-- writepixelsbuffer is the current name (post-2024 roblox)
	local ok = pcall(function() img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), buf) end)
	if ok then return end
	-- older builds called it writepixels
	local ok2 = pcall(function() img:WritePixels(Vector2.zero, Vector2.new(w, h), buf) end)
	if ok2 then return end
	-- last resort: drawpixel per-pixel (slow but always works)
	for py = 0, h - 1 do
		for px = 0, w - 1 do
			local base = (py * w + px) * 4
			local r = buffer.readu8(buf, base)     / 255
			local g = buffer.readu8(buf, base + 1) / 255
			local b = buffer.readu8(buf, base + 2) / 255
			img:DrawPixel(Vector2.new(px, py), Color3.new(r, g, b), 1)
		end
	end
end

-- frame payload: 8-byte le w/h header + rgba pixels (same wire format as
-- tools/play.luau), plus a hud status line refreshed ~1x/second.
local function applyFrame(payload, w, h, statusText)
	if type(payload) ~= "string" or w <= 0 or h <= 0 then return end

	if not currentImage or lastW ~= w or lastH ~= h then
		if currentImage then pcall(function() currentImage:Destroy() end) end
		local ok, img = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		end)
		if not ok or not img then
			statusLabel.Text = "PS1  ·  EditableImage is unavailable in this Studio build"
			return
		end
		currentImage = img
		label.ImageContent = Content.fromObject(currentImage)
		lastW, lastH = w, h
	end

	-- skip the 8-byte header if present, then hand the bytes straight to the
	-- image (no per-pixel luau loop).
	local pixels = payload
	if #payload >= 8 + w * h * 4 then
		pixels = payload:sub(9)
	end
	if #pixels < w * h * 4 then return end
	local buf = buffer.fromstring(pixels)
	writePixelsToImage(currentImage, w, h, buf)

	frameCount += 1
	-- show the server's hud line once it arrives; keep the controls hint
	-- until then.
	if type(statusText) == "string" and #statusText > 0 then
		statusLabel.Text = statusText
	else
		statusLabel.Text = string.format("PS1  ·  frame %d  ·  %dx%d  ·  arrows/WASD move  ·  X Cross  ·  C Circle  ·  Enter Start", frameCount, w, h)
	end
end

frameEvent.OnClientEvent:Connect(function(payload, w, h, statusText)
	local ok, err = pcall(applyFrame, payload, w, h, statusText)
	if not ok then
		statusLabel.Text = "PS1  ·  display error: " .. tostring(err)
	end
end)

-- same mapping as the browser front-end (tools/play.luau).
local inputEvent = ReplicatedStorage:WaitForChild("PS1InputEvent", 10)
local MAP = {
	W = 0x0010, Up = 0x0010,
	S = 0x0040, Down = 0x0040,
	A = 0x0080, Left = 0x0080,
	D = 0x0020, Right = 0x0020,
	X = 0x4000, J = 0x4000, K = 0x4000,     -- Cross
	C = 0x2000, L = 0x2000,                 -- Circle
	T = 0x1000, Y = 0x1000,                 -- Triangle
	V = 0x8000, U = 0x8000,                 -- Square
	Return = 0x0008,                        -- Start
	Backspace = 0x0001,                     -- Select
	Q = 0x0400, E = 0x0800,                 -- L1 R1
	One = 0x0100, Three = 0x0200,           -- L2 R2
}

local heldMask = 0
local lastSent = -1
local function sendInput()
	if not inputEvent then return end
	if heldMask == lastSent then return end
	lastSent = heldMask
	inputEvent:FireServer(heldMask)
end

local function keyToMask(key)
	if type(key) ~= "string" then return nil end
	-- keycode.name is already canonical ("w", "up", "return"); the uppercase fallback only exists for builds that report lowercase letters.
	local m = MAP[key]
	if m then return m end
	m = MAP[string.upper(key)]
	if m then return m end
	if key == "1" then return 0x0100 end
	if key == "3" then return 0x0200 end
	return nil
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local mask = keyToMask(input.KeyCode.Name)
	if mask then
		heldMask = bit32.bor(heldMask, mask)
		sendInput()
	end
end)

UserInputService.InputEnded:Connect(function(input, _gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local mask = keyToMask(input.KeyCode.Name)
	if mask then
		heldMask = bit32.band(heldMask, bit32.bnot(mask))
		sendInput()
	end
end)