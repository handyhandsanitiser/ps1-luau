-- ps1 gte (geometry transformation engine / cop2).  the weird parts (unr division, mac
-- overflow wrap, sign/zero-extension quirks, the mvmva fc path and garbage matrix, the
-- ncs light/color split, interpolatecolor's two steps, rtps sz3/ir3 rules) are hardware
-- behavior, kept explicit.  flag layout per psx-spx cop2r63 / duckstation.
-- register layout (checkpoint-compatible): dr[0..31] data regs, cr[0..31] control regs,
-- mac[0..3] raw accumulators (dr[24..27] authoritative).
local GTE = {}
GTE.__index = GTE

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local bnot   = bit32.bnot

local MAC0_MIN = -(2 ^ 31)
local MAC0_MAX = (2 ^ 31) - 1
local MAC123_MIN = -(2 ^ 43)
local MAC123_MAX = (2 ^ 43) - 1
local IR0_MIN = 0
local IR0_MAX = 0x1000
local IR123_MIN = -0x8000
local IR123_MAX = 0x7FFF

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end
local function trunc16(v) return band(v, 0xFFFF) end
local function trunc32(v) return band(v, 0xFFFFFFFF) end
local function s16(v) v = band(v, 0xFFFF); if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = band(v, 0xFFFFFFFF); if v >= 0x80000000 then return v - 0x100000000 end return v end

-- wrap to n bits (two's complement), not saturate
local function wrap44(value)
	local m = value % 0x100000000000
	if m >= 0x80000000000 then m = m - 0x100000000000 end
	return m
end
local function wrap31(value)
	local m = value % 0x80000000
	if m >= 0x40000000 then m = m - 0x80000000 end
	return m
end

-- unr reciprocal table (from psx-spx / duckstation)
local unr_table = {
	0xFF, 0xFD, 0xFB, 0xF9, 0xF7, 0xF5, 0xF3, 0xF1, 0xEF, 0xEE, 0xEC, 0xEA, 0xE8, 0xE6, 0xE4, 0xE3,
	0xE1, 0xDF, 0xDD, 0xDC, 0xDA, 0xD8, 0xD6, 0xD5, 0xD3, 0xD1, 0xD0, 0xCE, 0xCD, 0xCB, 0xC9, 0xC8,
	0xC6, 0xC5, 0xC3, 0xC1, 0xC0, 0xBE, 0xBD, 0xBB, 0xBA, 0xB8, 0xB7, 0xB5, 0xB4, 0xB2, 0xB1, 0xB0,
	0xAE, 0xAD, 0xAB, 0xAA, 0xA9, 0xA7, 0xA6, 0xA4, 0xA3, 0xA2, 0xA0, 0x9F, 0x9E, 0x9C, 0x9B, 0x9A,
	0x99, 0x97, 0x96, 0x95, 0x94, 0x92, 0x91, 0x90, 0x8F, 0x8D, 0x8C, 0x8B, 0x8A, 0x89, 0x87, 0x86,
	0x85, 0x84, 0x83, 0x82, 0x81, 0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x7A, 0x79, 0x78, 0x77, 0x75, 0x74,
	0x73, 0x72, 0x71, 0x70, 0x6F, 0x6E, 0x6D, 0x6C, 0x6B, 0x6A, 0x69, 0x68, 0x67, 0x66, 0x65, 0x64,
	0x63, 0x62, 0x61, 0x60, 0x5F, 0x5E, 0x5D, 0x5D, 0x5C, 0x5B, 0x5A, 0x59, 0x58, 0x57, 0x56, 0x55,
	0x54, 0x53, 0x53, 0x52, 0x51, 0x50, 0x4F, 0x4E, 0x4D, 0x4D, 0x4C, 0x4B, 0x4A, 0x49, 0x48, 0x48,
	0x47, 0x46, 0x45, 0x44, 0x43, 0x43, 0x42, 0x41, 0x40, 0x3F, 0x3F, 0x3E, 0x3D, 0x3C, 0x3C, 0x3B,
	0x3A, 0x39, 0x39, 0x38, 0x37, 0x36, 0x36, 0x35, 0x34, 0x33, 0x33, 0x32, 0x31, 0x31, 0x30, 0x2F,
	0x2E, 0x2E, 0x2D, 0x2C, 0x2C, 0x2B, 0x2A, 0x2A, 0x29, 0x28, 0x28, 0x27, 0x26, 0x26, 0x25, 0x24,
	0x24, 0x23, 0x22, 0x22, 0x21, 0x20, 0x20, 0x1F, 0x1E, 0x1E, 0x1D, 0x1D, 0x1C, 0x1B, 0x1B, 0x1A,
	0x19, 0x19, 0x18, 0x18, 0x17, 0x16, 0x16, 0x15, 0x15, 0x14, 0x14, 0x13, 0x12, 0x12, 0x11, 0x11,
	0x10, 0x0F, 0x0F, 0x0E, 0x0E, 0x0D, 0x0D, 0x0C, 0x0C, 0x0B, 0x0A, 0x0A, 0x09, 0x09, 0x08, 0x08,
	0x07, 0x07, 0x06, 0x06, 0x05, 0x05, 0x04, 0x04, 0x03, 0x03, 0x02, 0x02, 0x01, 0x01, 0x00, 0x00,
	0x00,
}

local function countLeadingZeros16(v)
	-- v is 0..0xffff; returns 0..16
	local n = 0
	while v ~= 0 do
		v = rshift(v, 1)
		n = n + 1
	end
	return 16 - n
end

local function countLeadingBits(v)
	-- 32-bit: if top bit set, invert, then count leading zeros
	local t = v
	if band(t, 0x80000000) ~= 0 then t = bnot(t) end
	local n = 0
	local mask = 0x80000000
	while n < 32 and band(t, mask) == 0 do
		n = n + 1
		mask = rshift(mask, 1)
	end
	return n
end

-- construction and register access

function GTE.new()
	local self = setmetatable({}, GTE)
	self.dr = {}
	self.cr = {}
	self.mac = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	for i = 0, 31 do self.dr[i] = 0; self.cr[i] = 0 end
	return self
end

-- matrix element (r,c) 0-based from cr base word (base: rt=0, llm=8, lcm=16)
local function getM(self, base, r, c)
	local i = r * 3 + c
	local w = self.cr[base + (i // 2)]
	if i % 2 == 0 then return s16(band(w, 0xFFFF)) else return s16(rshift(w, 16)) end
end
local function getV(self, vn)
	local xy = self.dr[vn * 2]
	local z = self.dr[vn * 2 + 1]
	return s16(band(xy, 0xFFFF)), s16(rshift(xy, 16)), s16(band(z, 0xFFFF))
end
local function getIR(self, n)
	return s16(self.dr[8 + n])
end
local function getMac(self, idx)
	return s32(self.dr[24 + idx])
end

function GTE:readData(reg)
	reg = band(reg, 31)
	if reg == 15 then
		-- sxy3: mirror of sxy2
		return self.dr[14]
	elseif reg == 28 or reg == 29 then
		-- irgb/orgb: convert 16-bit ir1-3 to 555
		local r = clamp(getIR(self, 1) // 0x80, 0x00, 0x1F)
		local g = clamp(getIR(self, 2) // 0x80, 0x00, 0x1F)
		local b = clamp(getIR(self, 3) // 0x80, 0x00, 0x1F)
		return bor(r, lshift(g, 5), lshift(b, 10))
	end
	return self.dr[reg]
end

function GTE:readCtrl(reg)
	reg = band(reg, 31)
	return self.cr[reg]
end

local function signExtend16(v)
	v = trunc16(v)
	if v >= 0x8000 then return v - 0x10000 end
	return v
end

function GTE:writeData(reg, value)
	reg = band(reg, 31)
	value = trunc32(value)
	if reg == 1 or reg == 3 or reg == 5 or reg == 8 or reg == 9 or reg == 10 or reg == 11 then
		-- sign-extend 16-bit registers (v0z,v1z,v2z, ir0-3)
		self.dr[reg] = trunc32(signExtend16(value))
	elseif reg == 7 or reg == 16 or reg == 17 or reg == 18 or reg == 19 then
		-- zero-extend unsigned 16-bit registers (otz, sz0-3)
		self.dr[reg] = trunc16(value)
	elseif reg == 15 then
		-- writing to sxyp pushes to the fifo
		self.dr[12] = self.dr[13]
		self.dr[13] = self.dr[14]
		self.dr[14] = value
	elseif reg == 28 then
		-- irgb: convert 555 to ir1-3
		self.dr[28] = band(value, 0x7FFF)
		self.dr[9] = trunc32(signExtend16(trunc16(band(value, 0x1F)) * 0x80))
		self.dr[10] = trunc32(signExtend16(trunc16(band(rshift(value, 5), 0x1F)) * 0x80))
		self.dr[11] = trunc32(signExtend16(trunc16(band(rshift(value, 10), 0x1F)) * 0x80))
	elseif reg == 30 then
		-- lzcs
		self.dr[30] = value
		self.dr[31] = countLeadingBits(value)
	elseif reg == 29 or reg == 31 then
		-- orgb / lzcr: read-only
	else
		self.dr[reg] = value
	end
end

function GTE:writeCtrl(reg, value)
	reg = band(reg, 31)
	value = trunc32(value)
	if reg == 4 or reg == 12 or reg == 20 or reg == 26 or reg == 27 or reg == 29 or reg == 30 then
		-- sign-extend 16-bit single-element control regs (rt33,l33,lr33,h,dqa,zsf3,zsf4)
		self.cr[reg] = trunc32(signExtend16(value))
	elseif reg == 31 then
		-- flag
		self.cr[reg] = band(value, 0x7FFFF000)
		if band(self.cr[reg], 0x7F87E000) ~= 0 then
			self.cr[reg] = bor(self.cr[reg], 0x80000000)
		end
	else
		self.cr[reg] = value
	end
end

-- flag helpers

local function flag(self, bit)
	self.cr[31] = bor(self.cr[31], lshift(1, bit))
end
local function clearFlag(self)
	self.cr[31] = 0
end
local function updateError(self)
	if band(self.cr[31], 0x7F87E000) ~= 0 then
		self.cr[31] = bor(self.cr[31], 0x80000000)
	end
end

-- check 44-bit (mac1-3) / 31-bit (mac0) overflow, set flags, wrap to n bits.
local function signExtendMACResult(self, idx, value)
	if idx == 0 then
		if value < MAC0_MIN then flag(self, 15)
		elseif value > MAC0_MAX then flag(self, 16) end
		return wrap31(value)
	else
		if value < MAC123_MIN then flag(self, 28 - idx)
		elseif value > MAC123_MAX then flag(self, 31 - idx) end
		return wrap44(value)
	end
end

-- truncateandsetmac: flag on raw value, store trunc32(value >> shift) into dr[24+idx]
local function setMAC(self, idx, value, shift)
	signExtendMACResult(self, idx, value)
	local shifted = math.floor(value * (2 ^ -shift))
	self.dr[24 + idx] = trunc32(shifted)
	self.mac[idx] = wrap44(value) -- raw accumulator for checkpoint compat
end

-- truncateandsetir: clamp to ir range (lm dependent), set flag, store sign-extended
local function setIR(self, idx, value, lm)
	local minv, maxv
	if idx == 0 then minv = IR0_MIN; maxv = IR0_MAX
	else minv = IR123_MIN; maxv = IR123_MAX end
	local actual_min = lm and 0 or minv
	if value < actual_min then
		value = actual_min
		flag(self, idx == 0 and 12 or (25 - idx))
	elseif value > maxv then
		value = maxv
		flag(self, idx == 0 and 12 or (25 - idx))
	end
	self.dr[8 + idx] = trunc32(value)
end

-- truncateandsetmacandir
local function setMACAndIR(self, idx, value, shift, lm)
	signExtendMACResult(self, idx, value)
	local shifted = math.floor(value * (2 ^ -shift))
	self.dr[24 + idx] = trunc32(shifted)
	self.mac[idx] = wrap44(value)
	setIR(self, idx, s32(shifted), lm)
end

-- division (the hardware unr approximation)

local function unrDivide(self, lhs, rhs)
	if rhs * 2 <= lhs then
		flag(self, 17) -- divide overflow
		return 0x1FFFF
	end
	local shift
	if rhs == 0 then shift = 16 else shift = countLeadingZeros16(rhs) end
	local n = lhs * (2 ^ shift)
	local d = rhs * (2 ^ shift)
	local divisor = bor(d, 0x8000)
	local x = 0x101 + unr_table[((band(divisor, 0x7FFF) + 0x40) // 0x80) + 1]
	local dd = ((divisor * -x) + 0x80) // 0x100
	local recip = ((x * (0x20000 + dd)) + 0x80) // 0x100
	local result = ((n * recip) + 0x8000) // 0x10000
	return math.min(0x1FFFF, result)
end

-- fifo push helpers

local function pushSXY(self, x, y)
	if x < -1024 then flag(self, 14); x = -1024
	elseif x > 1023 then flag(self, 14); x = 1023 end
	if y < -1024 then flag(self, 13); y = -1024
	elseif y > 1023 then flag(self, 13); y = 1023 end
	self.dr[12] = self.dr[13]
	self.dr[13] = self.dr[14]
	self.dr[14] = bor(band(x, 0xFFFF), lshift(band(y, 0xFFFF), 16))
end

local function pushSZ(self, value)
	if value < 0 then flag(self, 18); value = 0
	elseif value > 0xFFFF then flag(self, 18); value = 0xFFFF end
	self.dr[16] = self.dr[17]
	self.dr[17] = self.dr[18]
	self.dr[18] = self.dr[19]
	self.dr[19] = trunc32(value)
end

local function setOTZ(self, value)
	if value < 0 then flag(self, 18); value = 0
	elseif value > 0xFFFF then flag(self, 18); value = 0xFFFF end
	self.dr[7] = trunc32(value)
end

local function truncRGB(self, idx, value)
	if value < 0 or value > 0xFF then
		flag(self, 21 - idx)
		return value < 0 and 0 or 0xFF
	end
	return value
end

local function pushRGBFromMAC(self)
	-- arithmetic shift by 4 on the s32 mac value (floor)
	local r = truncRGB(self, 0, math.floor(getMac(self, 1) / 16))
	local g = truncRGB(self, 1, math.floor(getMac(self, 2) / 16))
	local b = truncRGB(self, 2, math.floor(getMac(self, 3) / 16))
	local c = band(self.dr[6], 0xFF000000) // 0x1000000 -- RGBC[3] code byte
	self.dr[20] = self.dr[21]
	self.dr[21] = self.dr[22]
	self.dr[22] = bor(r, lshift(g, 8), lshift(b, 16), lshift(c, 24))
end

-- matrix and vector operations

-- mulmatvec without translation: mac = m*v; `base` is the control-register word holding the 3x3 matrix (rt=0, llm=8, lcm=16).
local function mulMatVec(self, base, Vx, Vy, Vz, shift, lm)
	for i = 0, 2 do
		local v = signExtendMACResult(self, i + 1, (getM(self, base, i, 0) * Vx) + (getM(self, base, i, 1) * Vy))
		v = v + (getM(self, base, i, 2) * Vz)
		setMACAndIR(self, i + 1, v, shift, lm)
	end
end

-- mulmatvec with translation: mac = (t<<12) + m*v (t passed as three scalars
-- to avoid allocating a per-call table).
local function mulMatVecT(self, base, T0, T1, T2, Vx, Vy, Vz, shift, lm)
	for i = 0, 2 do
		local t = i == 0 and T0 or (i == 1 and T1 or T2)
		local v = signExtendMACResult(self, i + 1, (t * 0x1000) + (getM(self, base, i, 0) * Vx))
		v = signExtendMACResult(self, i + 1, v + (getM(self, base, i, 1) * Vy))
		v = v + (getM(self, base, i, 2) * Vz)
		setMACAndIR(self, i + 1, v, shift, lm)
	end
end

-- mulmatvecbuggy (mvmva with fc translation): first term only affects ir
-- (lm=false), mac is reduced to the last two columns.
local function mulMatVecBuggy(self, base, T0, T1, T2, Vx, Vy, Vz, shift, lm)
	for i = 0, 2 do
		local t = i == 0 and T0 or (i == 1 and T1 or T2)
		local first = signExtendMACResult(self, i + 1, (t * 0x1000) + (getM(self, base, i, 0) * Vx))
		setIR(self, i + 1, s32(math.floor(first * (2 ^ -shift))), false)
		local v = signExtendMACResult(self, i + 1, getM(self, base, i, 1) * Vy)
		v = v + (getM(self, base, i, 2) * Vz)
		setMACAndIR(self, i + 1, v, shift, lm)
	end
end

-- mvmva mx=3 "garbage matrix" (rows -r16/r16/ir0, rt13, rt22) for the buggy fc path, unrolled.
local function mulMatVecBuggy3(self, T0, T1, T2, Vx, Vy, Vz, shift, lm)
	local r = band(self.dr[6], 0xFF)
	local r16 = s16(lshift(r, 4))
	local rt13 = getM(self, 0, 0, 2)
	local rt22 = getM(self, 0, 1, 1)
	local ir0 = s16(self.dr[8])
	-- row 0: (-r16, r16, ir0)
	local first = signExtendMACResult(self, 1, (T0 * 0x1000) + ((-r16) * Vx))
	setIR(self, 1, s32(math.floor(first * (2 ^ -shift))), false)
	local v = signExtendMACResult(self, 1, r16 * Vy)
	v = v + (ir0 * Vz)
	setMACAndIR(self, 1, v, shift, lm)
	-- row 1: (rt13, rt13, rt13)
	first = signExtendMACResult(self, 2, (T1 * 0x1000) + (rt13 * Vx))
	setIR(self, 2, s32(math.floor(first * (2 ^ -shift))), false)
	v = signExtendMACResult(self, 2, rt13 * Vy)
	v = v + (rt13 * Vz)
	setMACAndIR(self, 2, v, shift, lm)
	-- row 2: (rt22, rt22, rt22)
	first = signExtendMACResult(self, 3, (T2 * 0x1000) + (rt22 * Vx))
	setIR(self, 3, s32(math.floor(first * (2 ^ -shift))), false)
	v = signExtendMACResult(self, 3, rt22 * Vy)
	v = v + (rt22 * Vz)
	setMACAndIR(self, 3, v, shift, lm)
end

-- colour interpolation

local function interpolateColor(self, in_MAC1, in_MAC2, in_MAC3, shift, lm)
	-- [mac1..3] = (fc<<12 - in_mac) sar (sf*12), ir = clamp (lm=false)
	setMACAndIR(self, 1, (s32(self.cr[21]) * 0x1000) - in_MAC1, shift, false)
	setMACAndIR(self, 2, (s32(self.cr[22]) * 0x1000) - in_MAC2, shift, false)
	setMACAndIR(self, 3, (s32(self.cr[23]) * 0x1000) - in_MAC3, shift, false)
	-- [mac1..3] = (ir * ir0 + in_mac) sar (sf*12)
	local ir0 = s16(self.dr[8])
	setMACAndIR(self, 1, (getIR(self, 1) * ir0) + in_MAC1, shift, lm)
	setMACAndIR(self, 2, (getIR(self, 2) * ir0) + in_MAC2, shift, lm)
	setMACAndIR(self, 3, (getIR(self, 3) * ir0) + in_MAC3, shift, lm)
end

-- rtps and rtpt

-- one row of the rtps/rtpt transform dot product (tr + m*v); module-level so rtpt doesn't allocate 9 closures per instruction.
local function rtpsDot(self, i, vx, vy, vz)
	local v = signExtendMACResult(self, i + 1, (s32(self.cr[5 + i]) * 0x1000) + (getM(self, 0, i, 0) * vx))
	v = signExtendMACResult(self, i + 1, v + (getM(self, 0, i, 1) * vy))
	v = v + (getM(self, 0, i, 2) * vz)
	return v
end

local function rtps(self, vx, vy, vz, shift, lm, last)
	local x = rtpsDot(self, 0, vx, vy, vz)
	local y = rtpsDot(self, 1, vx, vy, vz)
	local z = rtpsDot(self, 2, vx, vy, vz)

	setMAC(self, 1, x, shift)
	setMAC(self, 2, y, shift)
	setMAC(self, 3, z, shift)
	setIR(self, 1, s32(self.dr[25]), lm)
	setIR(self, 2, s32(self.dr[26]), lm)
	-- ir3: flag from z>>12 with lm=0 semantics; stored value from mac3 with lm
	setIR(self, 3, s32(math.floor(z * (2 ^ -12))), false)
	self.dr[11] = trunc32(clamp(getMac(self, 3), lm and 0 or IR123_MIN, IR123_MAX))

	-- sz3 = z >> 12 (always; mac3 is z>>shift, so this is mac3 sar ((1-sf)*12))
	pushSZ(self, s32(math.floor(z * (2 ^ -12))))

	-- q = unr(h, sz3); h = cr26 low 16
	local result = unrDivide(self, band(self.cr[26], 0xFFFF), band(self.dr[19], 0xFFFF))

	local Sx = (result * s16(self.dr[9])) + s32(self.cr[24])
	local Sy = (result * s16(self.dr[10])) + s32(self.cr[25])
	signExtendMACResult(self, 0, Sx)
	signExtendMACResult(self, 0, Sy)
	pushSXY(self, s32(math.floor(Sx * (2 ^ -16))), s32(math.floor(Sy * (2 ^ -16))))

	if last then
		-- mac0 = q*dqa + dqb, ir0 = mac0>>12 (0..0x1000, lm=true)
		local Sz = (result * s16(self.cr[27])) + s32(self.cr[28])
		setMAC(self, 0, Sz, 0)
		setIR(self, 0, s32(math.floor(Sz * (2 ^ -12))), true)
	end
end

-- opcode implementations

local function executeRTPS(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0)
	rtps(self, vx, vy, vz, shift, lm, true)
	updateError(self)
end

local function executeRTPT(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx0, vy0, vz0 = getV(self, 0)
	local vx1, vy1, vz1 = getV(self, 1)
	local vx2, vy2, vz2 = getV(self, 2)
	rtps(self, vx0, vy0, vz0, shift, lm, false)
	rtps(self, vx1, vy1, vz1, shift, lm, false)
	rtps(self, vx2, vy2, vz2, shift, lm, true)
	updateError(self)
end

local function executeNCLIP(self)
	clearFlag(self)
	local function sxy(n, c)
		local w = self.dr[12 + n]
		if c == 0 then return s16(band(w, 0xFFFF)) else return s16(rshift(w, 16)) end
	end
	local result = (sxy(0, 0) * sxy(1, 1)) + (sxy(1, 0) * sxy(2, 1)) + (sxy(2, 0) * sxy(0, 1))
		- (sxy(0, 0) * sxy(2, 1)) - (sxy(1, 0) * sxy(0, 1)) - (sxy(2, 0) * sxy(1, 1))
	setMAC(self, 0, result, 0)
	updateError(self)
end

local function executeAVSZ3(self)
	clearFlag(self)
	local result = s16(self.cr[29]) * s32(trunc32(self.dr[17] + self.dr[18] + self.dr[19]))
	setMAC(self, 0, result, 0)
	setOTZ(self, s32(math.floor(result * (2 ^ -12))))
	updateError(self)
end

local function executeAVSZ4(self)
	clearFlag(self)
	local result = s16(self.cr[30]) * s32(trunc32(self.dr[16] + self.dr[17] + self.dr[18] + self.dr[19]))
	setMAC(self, 0, result, 0)
	setOTZ(self, s32(math.floor(result * (2 ^ -12))))
	updateError(self)
end

local function executeMVMVA(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local mx = band(rshift(inst, 17), 3)
	local vx = band(rshift(inst, 15), 3)
	local tx = band(rshift(inst, 13), 3)

	local Vx, Vy, Vz
	if vx <= 2 then
		Vx, Vy, Vz = getV(self, vx)
	else
		Vx = getIR(self, 1); Vy = getIR(self, 2); Vz = getIR(self, 3)
	end

	local T0, T1, T2
	if tx == 0 then T0 = s32(self.cr[5]); T1 = s32(self.cr[6]); T2 = s32(self.cr[7])
	elseif tx == 1 then T0 = s32(self.cr[13]); T1 = s32(self.cr[14]); T2 = s32(self.cr[15])
	elseif tx == 2 then T0 = s32(self.cr[21]); T1 = s32(self.cr[22]); T2 = s32(self.cr[23])
	else T0, T1, T2 = 0, 0, 0 end

	if tx ~= 2 then
		if mx == 3 then
			-- mx=3 garbage matrix only: keep a closure here (rare path) so the
			-- common mx=0/1/2 cases stay allocation-free.
			local r = band(self.dr[6], 0xFF)
			local r16 = s16(lshift(r, 4))
			local rt13 = getM(self, 0, 0, 2)
			local rt22 = getM(self, 0, 1, 1)
			local ir0 = s16(self.dr[8])
			local M = function(i, j)
				if i == 0 then
					if j == 0 then return -r16 elseif j == 1 then return r16 else return ir0 end
				elseif i == 1 then return rt13
				else return rt22 end
			end
			for i = 0, 2 do
				local t = i == 0 and T0 or (i == 1 and T1 or T2)
				local v = signExtendMACResult(self, i + 1, (t * 0x1000) + (M(i, 0) * Vx))
				v = signExtendMACResult(self, i + 1, v + (M(i, 1) * Vy))
				v = v + (M(i, 2) * Vz)
				setMACAndIR(self, i + 1, v, shift, lm)
			end
		else
			mulMatVecT(self, mx * 8, T0, T1, T2, Vx, Vy, Vz, shift, lm)
		end
	elseif mx == 3 then
		mulMatVecBuggy3(self, T0, T1, T2, Vx, Vy, Vz, shift, lm)
	else
		mulMatVecBuggy(self, mx * 8, T0, T1, T2, Vx, Vy, Vz, shift, lm)
	end
	updateError(self)
end

local function executeSQR(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local i1, i2, i3 = s16(self.dr[9]), s16(self.dr[10]), s16(self.dr[11])
	self.dr[25] = trunc32(math.floor((i1 * i1) * (2 ^ -shift)))
	self.dr[26] = trunc32(math.floor((i2 * i2) * (2 ^ -shift)))
	self.dr[27] = trunc32(math.floor((i3 * i3) * (2 ^ -shift)))
	self.mac[1], self.mac[2], self.mac[3] = i1 * i1, i2 * i2, i3 * i3
	setIR(self, 1, s32(self.dr[25]), lm)
	setIR(self, 2, s32(self.dr[26]), lm)
	setIR(self, 3, s32(self.dr[27]), lm)
	updateError(self)
end

local function executeOP(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local d1 = getM(self, 0, 0, 0)
	local d2 = getM(self, 0, 1, 1)
	local d3 = getM(self, 0, 2, 2)
	local ir1, ir2, ir3 = getIR(self, 1), getIR(self, 2), getIR(self, 3)
	setMACAndIR(self, 1, (ir3 * d2) - (ir2 * d3), shift, lm)
	setMACAndIR(self, 2, (ir1 * d3) - (ir3 * d1), shift, lm)
	setMACAndIR(self, 3, (ir2 * d1) - (ir1 * d2), shift, lm)
	updateError(self)
end

-- ncs-family light pass: (llm*v) sar (sf*12) -- no translation
local function lightPass(self, Vx, Vy, Vz, shift, lm)
	mulMatVec(self, 8, Vx, Vy, Vz, shift, lm)
end

-- ncs-family color pass: (bk*1000h + lcm*ir) sar (sf*12)
local function colorPass(self, shift, lm)
	mulMatVecT(self, 16, s32(self.cr[13]), s32(self.cr[14]), s32(self.cr[15]),
		getIR(self, 1), getIR(self, 2), getIR(self, 3), shift, lm)
end

local function ncs(self, vx, vy, vz, shift, lm)
	lightPass(self, vx, vy, vz, shift, lm)
	colorPass(self, shift, lm)
	pushRGBFromMAC(self)
end

local function executeNCS(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0)
	ncs(self, vx, vy, vz, shift, lm)
	updateError(self)
end

local function executeNCT(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0); ncs(self, vx, vy, vz, shift, lm)
	vx, vy, vz = getV(self, 1); ncs(self, vx, vy, vz, shift, lm)
	vx, vy, vz = getV(self, 2); ncs(self, vx, vy, vz, shift, lm)
	updateError(self)
end

local function nccs(self, vx, vy, vz, shift, lm)
	lightPass(self, vx, vy, vz, shift, lm)
	colorPass(self, shift, lm)
	local r = band(self.dr[6], 0xFF)
	local g = band(rshift(self.dr[6], 8), 0xFF)
	local b = band(rshift(self.dr[6], 16), 0xFF)
	setMACAndIR(self, 1, (r * getIR(self, 1)) * 0x10, shift, lm)
	setMACAndIR(self, 2, (g * getIR(self, 2)) * 0x10, shift, lm)
	setMACAndIR(self, 3, (b * getIR(self, 3)) * 0x10, shift, lm)
	pushRGBFromMAC(self)
end

local function executeNCCS(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0)
	nccs(self, vx, vy, vz, shift, lm)
	updateError(self)
end

local function executeNCCT(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0); nccs(self, vx, vy, vz, shift, lm)
	vx, vy, vz = getV(self, 1); nccs(self, vx, vy, vz, shift, lm)
	vx, vy, vz = getV(self, 2); nccs(self, vx, vy, vz, shift, lm)
	updateError(self)
end

local function ncds(self, vx, vy, vz, shift, lm)
	lightPass(self, vx, vy, vz, shift, lm)
	colorPass(self, shift, lm)
	local r = band(self.dr[6], 0xFF)
	local g = band(rshift(self.dr[6], 8), 0xFF)
	local b = band(rshift(self.dr[6], 16), 0xFF)
	interpolateColor(self, (r * getIR(self, 1)) * 0x10, (g * getIR(self, 2)) * 0x10, (b * getIR(self, 3)) * 0x10, shift, lm)
	pushRGBFromMAC(self)
end

local function executeNCDS(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0)
	ncds(self, vx, vy, vz, shift, lm)
	updateError(self)
end

local function executeNCDT(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local vx, vy, vz = getV(self, 0); ncds(self, vx, vy, vz, shift, lm)
	vx, vy, vz = getV(self, 1); ncds(self, vx, vy, vz, shift, lm)
	vx, vy, vz = getV(self, 2); ncds(self, vx, vy, vz, shift, lm)
	updateError(self)
end

local function executeCC(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	colorPass(self, shift, lm)
	local r = band(self.dr[6], 0xFF)
	local g = band(rshift(self.dr[6], 8), 0xFF)
	local b = band(rshift(self.dr[6], 16), 0xFF)
	setMACAndIR(self, 1, (r * getIR(self, 1)) * 0x10, shift, lm)
	setMACAndIR(self, 2, (g * getIR(self, 2)) * 0x10, shift, lm)
	setMACAndIR(self, 3, (b * getIR(self, 3)) * 0x10, shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

local function executeCDP(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	colorPass(self, shift, lm)
	local r = band(self.dr[6], 0xFF)
	local g = band(rshift(self.dr[6], 8), 0xFF)
	local b = band(rshift(self.dr[6], 16), 0xFF)
	interpolateColor(self, (r * getIR(self, 1)) * 0x10, (g * getIR(self, 2)) * 0x10, (b * getIR(self, 3)) * 0x10, shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

local function dpcs(self, r, g, b, shift, lm)
	-- [mac1..3] = [r,g,b] shl 16
	setMAC(self, 1, r * 0x10000, 0)
	setMAC(self, 2, g * 0x10000, 0)
	setMAC(self, 3, b * 0x10000, 0)
	interpolateColor(self, getMac(self, 1), getMac(self, 2), getMac(self, 3), shift, lm)
end

local function executeDPCS(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	dpcs(self, band(self.dr[6], 0xFF), band(rshift(self.dr[6], 8), 0xFF), band(rshift(self.dr[6], 16), 0xFF), shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

local function executeDPCT(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	for _ = 1, 3 do
		dpcs(self, band(self.dr[20], 0xFF), band(rshift(self.dr[20], 8), 0xFF), band(rshift(self.dr[20], 16), 0xFF), shift, lm)
		pushRGBFromMAC(self)
	end
	updateError(self)
end

local function executeDCPL(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local r = band(self.dr[6], 0xFF)
	local g = band(rshift(self.dr[6], 8), 0xFF)
	local b = band(rshift(self.dr[6], 16), 0xFF)
	interpolateColor(self, (r * getIR(self, 1)) * 0x10, (g * getIR(self, 2)) * 0x10, (b * getIR(self, 3)) * 0x10, shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

local function executeINTPL(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	interpolateColor(self, getIR(self, 1) * 0x1000, getIR(self, 2) * 0x1000, getIR(self, 3) * 0x1000, shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

local function executeGPF(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local ir0 = s16(self.dr[8])
	setMACAndIR(self, 1, getIR(self, 1) * ir0, shift, lm)
	setMACAndIR(self, 2, getIR(self, 2) * ir0, shift, lm)
	setMACAndIR(self, 3, getIR(self, 3) * ir0, shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

local function executeGPL(self, inst)
	clearFlag(self)
	local shift = band(rshift(inst, 19), 1) == 1 and 12 or 0
	local lm = band(rshift(inst, 10), 1) == 1
	local ir0 = s16(self.dr[8])
	setMACAndIR(self, 1, (getIR(self, 1) * ir0) + (getMac(self, 1) * (2 ^ shift)), shift, lm)
	setMACAndIR(self, 2, (getIR(self, 2) * ir0) + (getMac(self, 2) * (2 ^ shift)), shift, lm)
	setMACAndIR(self, 3, (getIR(self, 3) * ir0) + (getMac(self, 3) * (2 ^ shift)), shift, lm)
	pushRGBFromMAC(self)
	updateError(self)
end

-- dispatch

-- per-op execution latency in cpu cycles (duckstation addgteticks; matches psx-spx gtepipelinetimings.md).  the gte runs in the background: the next gte-dependent instruction stalls until the in-flight op completes.
local GTE_TICKS = {
	[0x01] = 15, -- RTPS
	[0x06] = 8,  -- NCLIP
	[0x0C] = 6,  -- OP
	[0x10] = 8,  -- DPCS
	[0x11] = 8,  -- INTPL
	[0x12] = 8,  -- MVMVA
	[0x13] = 19, -- NCDS
	[0x14] = 13, -- CDP
	[0x16] = 44, -- NCDT
	[0x1B] = 17, -- NCCS
	[0x1C] = 11, -- CC
	[0x1E] = 14, -- NCS
	[0x20] = 30, -- NCT
	[0x28] = 5,  -- SQR
	[0x29] = 8,  -- DCPL
	[0x2A] = 17, -- DPCT
	[0x2D] = 5,  -- AVSZ3
	[0x2E] = 6,  -- AVSZ4
	[0x30] = 23, -- RTPT
	[0x3D] = 5,  -- GPF
	[0x3E] = 5,  -- GPL
	[0x3F] = 39, -- NCCT
}

-- cycle latency of a cop2 data op (command = low 6 bits, duckstation
-- instruction::command).  returns 0 for unknown commands.
function GTE:opTicks(cmd)
	return GTE_TICKS[band(cmd, 0x3F)] or 0
end

function GTE:execute(cmd)
	local op = band(cmd, 0x3F)
	if op == 0x01 then executeRTPS(self, cmd)
	elseif op == 0x06 then executeNCLIP(self)
	elseif op == 0x0C then executeOP(self, cmd)
	elseif op == 0x10 then executeDPCS(self, cmd)
	elseif op == 0x11 then executeINTPL(self, cmd)
	elseif op == 0x12 then executeMVMVA(self, cmd)
	elseif op == 0x13 then executeNCDS(self, cmd)
	elseif op == 0x14 then executeCDP(self, cmd)
	elseif op == 0x16 then executeNCDT(self, cmd)
	elseif op == 0x1B then executeNCCS(self, cmd)
	elseif op == 0x1C then executeCC(self, cmd)
	elseif op == 0x1E then executeNCS(self, cmd)
	elseif op == 0x20 then executeNCT(self, cmd)
	elseif op == 0x28 then executeSQR(self, cmd)
	elseif op == 0x29 then executeDCPL(self, cmd)
	elseif op == 0x2A then executeDPCT(self, cmd)
	elseif op == 0x2D then executeAVSZ3(self)
	elseif op == 0x2E then executeAVSZ4(self)
	elseif op == 0x30 then executeRTPT(self, cmd)
	elseif op == 0x3D then executeGPF(self, cmd)
	elseif op == 0x3E then executeGPL(self, cmd)
	elseif op == 0x3F then executeNCCT(self, cmd)
	end
end

function GTE:read(register)
	return self:readData(register)
end
function GTE:write(register, value)
	self:writeData(register, value)
end

return GTE
