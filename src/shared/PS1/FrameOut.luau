-- rgb15 -> rgba8 frame encoder shared by the display front-ends (roblox remoteevent and the browser websocket).
-- wire format: 8-byte little-endian w/h header + pixel body -- w*h*4 bytes rgba (alpha 255) by default
-- (needed for writepixelsbuffer), or w*h*2 bytes rgb15 (mask/priority bit stripped) for the browser.

local FrameOut = {}

local band = bit32.band
local rshift = bit32.rshift

local PACK_BYTES = 512

-- vram is a flat 1-based array of 16-bit colors with a 1024-word row stride; the pack loop reads it directly and inlines the channel extraction (per-pixel method calls dominated pack time).
local VRAM_W = 1024

-- pack gpu's visible framebuffer into the wire byte string; rgb15 selects the 2-byte mode, nil keeps rgba.  returns payload, width, height, or nil when the display has no valid size.
function FrameOut.packFrame(gpu, rgb15)
	local sx, sy = gpu.displayStartX, gpu.displayStartY
	local w, h = gpu.displayWidth, gpu.displayHeight
	if not w or w <= 0 or not h or h <= 0 then
		return nil
	end

	local vram = gpu.vram
	local out = {}
	-- the chunk buffer is reused across flushes (string.char only reads 1..n, so stale tail values are harmless); a manual write index beats buf[#buf + 1].
	local buf = table.create(PACK_BYTES)
	local n = 0
	if rgb15 then
		-- two writes per pixel; the channel bits go out little-endian with bit 15 stripped, matching what the rgba masks display.
		for fy = 0, h - 1 do
			local idx = (sy + fy) * VRAM_W + sx + 1
			for _ = 1, w do
				local c = band(vram[idx] or 0, 0x7FFF)
				n += 1 buf[n] = band(c, 0xFF)
				n += 1 buf[n] = rshift(c, 8)
				idx += 1
				if n >= PACK_BYTES then
					out[#out + 1] = string.char(unpack(buf, 1, PACK_BYTES))
					n = 0
				end
			end
		end
	else
		for fy = 0, h - 1 do
			local idx = (sy + fy) * VRAM_W + sx + 1
			for _ = 1, w do
				local c = vram[idx] or 0
				n += 1 buf[n] = band(c, 0x1F) * 8
				n += 1 buf[n] = band(rshift(c, 5), 0x1F) * 8
				n += 1 buf[n] = band(rshift(c, 10), 0x1F) * 8
				n += 1 buf[n] = 255
				idx += 1
				if n >= PACK_BYTES then
					out[#out + 1] = string.char(unpack(buf, 1, PACK_BYTES))
					n = 0
				end
			end
		end
	end
	if n > 0 then
		out[#out + 1] = string.char(unpack(buf, 1, n))
	end

	local body = table.concat(out)
	local head = string.char(
		band(w, 0xFF), band(rshift(w, 8), 0xFF),
		band(rshift(w, 16), 0xFF), band(rshift(w, 24), 0xFF),
		band(h, 0xFF), band(rshift(h, 8), 0xFF),
		band(rshift(h, 16), 0xFF), band(rshift(h, 24), 0xFF))
	return head .. body, w, h
end

return FrameOut
