local Util = {}

local band = bit32.band
local bnot = bit32.bnot
local bxor = bit32.bxor
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_LOOKUP = {}

-- rfc 1321 md5 tables and rotation helper.
local function leftRotate(x, c)
	return bor(lshift(x, c), rshift(x, 32 - c))
end

local S = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local K = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local HEX = "0123456789abcdef"

for index = 1, #BASE64_ALPHABET do
	BASE64_LOOKUP[BASE64_ALPHABET:sub(index, index)] = index - 1
end

function Util.mask32(value)
	return band(value, 0xFFFFFFFF)
end

function Util.toSigned32(value)
	value = band(value, 0xFFFFFFFF)
	if band(value, 0x80000000) ~= 0 then
		return value - 0x100000000
	end
	return value
end

function Util.signExtend8(value)
	value = band(value, 0xFF)
	if band(value, 0x80) ~= 0 then
		return value - 0x100
	end
	return value
end

function Util.signExtend16(value)
	value = band(value, 0xFFFF)
	if band(value, 0x8000) ~= 0 then
		return value - 0x10000
	end
	return value
end

function Util.readU32LE(data, offset)
	local b1, b2, b3, b4 = data:byte(offset, offset + 3)
	if not b4 then
		return nil
	end
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- pure-luau md5 (rfc 1321) over byte strings; returns the 32-char lowercase hex digest.
function Util.md5(input)
	local data = input
	local len = #data
	local bitLenLow = band(len * 8, 0xFFFFFFFF)
	local bitLenHigh = band(math.floor(len / 0x20000000), 0xFFFFFFFF)
	local padLen = (56 - (len % 64) + 64) % 64
	if padLen == 0 then padLen = 64 end
	data = data .. string.char(0x80) .. string.rep("\0", padLen - 1)
	local nBlocks = (#data + 8) // 64
	local M = {}
	for b = 0, nBlocks - 1 do
		local block = {}
		for i = 0, 15 do
			local off = b * 64 + i * 4 + 1
			block[i + 1] = band(
				(data:byte(off) or 0) + (data:byte(off + 1) or 0) * 0x100
				+ (data:byte(off + 2) or 0) * 0x10000 + (data:byte(off + 3) or 0) * 0x1000000,
				0xFFFFFFFF
			)
		end
		M[b + 1] = block
	end
	local last = M[nBlocks]
	last[15] = bitLenLow
	last[16] = bitLenHigh

	local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
	for bi = 1, nBlocks do
		local blk = M[bi]
		local A, B, C, D = a0, b0, c0, d0
		for i = 0, 63 do
			local F, g
			if i < 16 then
				F = bor(band(B, C), band(bnot(B), D))
				g = i
			elseif i < 32 then
				F = bor(band(D, B), band(bnot(D), C))
				g = (5 * i + 1) % 16
			elseif i < 48 then
				F = bxor(bxor(B, C), D)
				g = (3 * i + 5) % 16
			else
				F = bxor(C, bor(B, bnot(D)))
				g = (7 * i) % 16
			end
			F = band(F + A + K[i + 1] + blk[g + 1], 0xFFFFFFFF)
			A, D, C, B = D, C, B, band(B + leftRotate(F, S[i + 1]), 0xFFFFFFFF)
		end
		a0 = band(a0 + A, 0xFFFFFFFF); b0 = band(b0 + B, 0xFFFFFFFF)
		c0 = band(c0 + C, 0xFFFFFFFF); d0 = band(d0 + D, 0xFFFFFFFF)
	end
	local function wordToHex(w)
		local out = {}
		for i = 0, 3 do
			local byte = band(rshift(w, i * 8), 0xFF)
			out[#out + 1] = HEX:sub(byte // 16 + 1, byte // 16 + 1)
			out[#out + 1] = HEX:sub(byte % 16 + 1, byte % 16 + 1)
		end
		return table.concat(out)
	end
	return wordToHex(a0) .. wordToHex(b0) .. wordToHex(c0) .. wordToHex(d0)
end

function Util.decodeBase64(data)
	assert(type(data) == "string", "decodeBase64 expects a string")

	local output = table.create(math.floor(#data * 3 / 4))
	local bytes = table.create(4096)
	local byteCount = 0
	local quartet = table.create(4)
	local quartetCount = 0
	local sawPadding = false

	local function emit(byte)
		byteCount += 1
		bytes[byteCount] = string.char(band(byte, 0xFF))
		if byteCount == 4096 then
			output[#output + 1] = table.concat(bytes)
			bytes = table.create(4096)
			byteCount = 0
		end
	end

	local function flushQuartet()
		local first = quartet[1]
		local second = quartet[2]
		local third = quartet[3]
		local fourth = quartet[4]
		assert(first ~= nil and second ~= nil, "decodeBase64 encountered truncated data")

		emit(bor(lshift(first, 2), rshift(second, 4)))
		if third ~= nil then
			emit(bor(lshift(band(second, 0x0F), 4), rshift(third, 2)))
		end
		if fourth ~= nil then
			emit(bor(lshift(band(third, 0x03), 6), fourth))
		end
	end

	for index = 1, #data do
		local character = data:sub(index, index)
		if character == "=" then
			sawPadding = true
		elseif character ~= "\r" and character ~= "\n" and character ~= "\t" and character ~= " " then
			assert(not sawPadding, "decodeBase64 has data after padding")
			local value = BASE64_LOOKUP[character]
			assert(value ~= nil, "decodeBase64 encountered invalid base64 data")
			quartetCount += 1
			quartet[quartetCount] = value
			if quartetCount == 4 then
				flushQuartet()
				quartet = table.create(4)
				quartetCount = 0
			end
		end
	end

	if quartetCount > 0 then
		assert(quartetCount == 2 or quartetCount == 3, "decodeBase64 encountered invalid length")
		flushQuartet()
	end
	if byteCount > 0 then
		-- table.concat(list, sep, i, j): pass "" as the separator and 1 as the start so the
		-- whole partial chunk is kept.  (table.concat(bytes, 1, byteCount) treated 1 as the
		-- separator and byteCount as the start, so every payload whose decoded length was not
		-- an exact multiple of 4096 bytes collapsed to ~1 byte -- sectors, checkpoints, etc.)
		output[#output + 1] = table.concat(bytes, "", 1, byteCount)
	end
	return table.concat(output)
end

return Util