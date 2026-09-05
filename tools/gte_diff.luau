-- gte execution differential: the core GTE (src/shared/PS1/GTE.luau) vs the reference model
-- (tools/gte_ref.luau), op by op.  cpudiff runs both cpus against a single shared gte, so any bug
-- inside gte agrees by construction -- this harness seeds identical register state into each model
-- and compares all 64 words after every executed command.
-- coverage: random single-command cases for every data op, long consecutive-op streams with
-- carried state (sticky flag, mac-accumulating ops), and a third phase driving the register-transfer
-- surface (writedata/writectrl -> readdata/readctrl over every register with boundary values, plus
-- sxyp fifo pushes and irgb/lzcs probes) that neither cpudiff nor array-seeded phases can reach.
-- the rng is a fixed-seed xorshift, so any drift reproduces.
-- usage: lune run tools/gte_diff.luau   (or via tools/run.luau gtediff)

local Loader = require("./lib/ps1loader")
local requirePs1 = Loader.createRequire()
local GTE = requirePs1("GTE")
local GTERef = require("./gte_ref")

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- the data ops the dispatch implements (execute is a no-op for any other
-- low-6-bit value, identically in both models)
local DATA_OPS = {
	0x01, 0x06, 0x0C, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x1B, 0x1C,
	0x1E, 0x20, 0x28, 0x29, 0x2A, 0x2D, 0x2E, 0x30, 0x3D, 0x3E, 0x3F,
}

local OPS_PER_CASE = 400
local STREAMS = 200
local STREAM_LENGTH = 32

local newFuzzRng = require("./lib/xorshift")

local function resetPair()
	local real = GTE.new()
	local ref = GTERef.new()
	-- the core keeps an informational 44-bit mac mirror for checkpoint compatibility; execute only reads dr[24..27], but keep the mirror consistent so no path can observe a stale copy.
	real.mac = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
	return real, ref
end

local function seedRegisters(real, ref, rng)
	for i = 0, 31 do
		local v = rng()
		real.dr[i] = v
		ref.dr[i] = v
	end
	for i = 0, 31 do
		local v = rng()
		real.cr[i] = v
		ref.cr[i] = v
	end
	-- clear the sticky flag bit so long random streams accumulate fresh flags
	-- (write 0 through the models' own mask so both end byte-identical)
	real.cr[31] = band(real.cr[31], 0x7FFFF000)
	ref.cr[31] = band(ref.cr[31], 0x7FFFF000)
	-- flag bit 31 is set by hardware whenever bits 13-30 hold anything
	-- (writectrl mirrors this); re-derive it the same way on both sides.
	if band(real.cr[31], 0x7F87E000) ~= 0 then
		real.cr[31] = band(bor(real.cr[31], 0x80000000), 0xFFFFFFFF)
		ref.cr[31] = band(bor(ref.cr[31], 0x80000000), 0xFFFFFFFF)
	end
end

local function compareState(real, ref)
	for i = 0, 31 do
		local a = real.dr[i] or 0
		local b = ref.dr[i] or 0
		if a ~= b then
			return string.format("dr[%d] core=%08X ref=%08X", i, band(a, 0xFFFFFFFF), band(b, 0xFFFFFFFF))
		end
	end
	for i = 0, 31 do
		local a = real.cr[i] or 0
		local b = ref.cr[i] or 0
		if a ~= b then
			return string.format("cr[%d] core=%08X ref=%08X", i, band(a, 0xFFFFFFFF), band(b, 0xFFFFFFFF))
		end
	end
	return nil
end

local function describe(cmd)
	return string.format("%08X (op=%02X)", band(cmd, 0xFFFFFFFF), band(cmd, 0x3F))
end

local function runOne(real, ref, cmd)
	real:execute(cmd)
	ref:execute(cmd)
	return compareState(real, ref)
end

local ok = true
local executed = 0

-- phase 1: each data op under random state and random mode bits
for _, op in ipairs(DATA_OPS) do
	local rng = newFuzzRng(0x6E7 + op * 0x101)
	for caseIndex = 1, OPS_PER_CASE do
		local real, ref = resetPair()
		seedRegisters(real, ref, rng)
		-- low 6 bits = the op; the upper bits are the mode fields (sf, lm, mvmva selectors, rtps fifo control) each op reads straight out of the word.
		local cmd = band(bor(op, lshift(band(rng(), 0x03FFFFFF), 6)), 0xFFFFFFFF)
		local diff = runOne(real, ref, cmd)
		if diff then
			print(string.format(
				"GTE DIFF op=%02X case=%d cmd=%s: %s",
				op, caseIndex, describe(cmd), diff
			))
			ok = false
			break
		end
		executed += 1
	end
	if not ok then
		break
	end
end

-- phase 2: consecutive-op streams with carried state (sticky flags, mac
-- accumulation across gpl/interpolate chains)
if ok then
	for s = 1, STREAMS do
		local rng = newFuzzRng(0xA11CE + s * 0x9E37)
		local real, ref = resetPair()
		seedRegisters(real, ref, rng)
		for c = 1, STREAM_LENGTH do
			local op = DATA_OPS[(rng() % #DATA_OPS) + 1]
			local cmd = band(bor(op, lshift(band(rng(), 0x03FFFFFF), 6)), 0xFFFFFFFF)
			local diff = runOne(real, ref, cmd)
			if diff then
				print(string.format(
					"GTE DIFF stream=%d/%d cmd=%s: %s",
					s, c, describe(cmd), diff
				))
				ok = false
				break
			end
			executed += 1
		end
		if not ok then
			break
		end
	end
end

-- phase 3: the register-transfer surface -- every register written through each model's writeData/writeCtrl with boundary values, then all state and readData/readCtrl outputs compared, plus sxyp fifo push chains and irgb/lzcs probes.
local transfers = 0

local function compareReads(real, ref)
	for i = 0, 31 do
		local a = real:readData(i)
		local b = ref:readData(i)
		if a ~= b then
			return string.format("readData(%d) core=%08X ref=%08X", i, band(a, 0xFFFFFFFF), band(b, 0xFFFFFFFF))
		end
	end
	for i = 0, 31 do
		local a = real:readCtrl(i)
		local b = ref:readCtrl(i)
		if a ~= b then
			return string.format("readCtrl(%d) core=%08X ref=%08X", i, band(a, 0xFFFFFFFF), band(b, 0xFFFFFFFF))
		end
	end
	return nil
end

local function checkTransfer(real, ref, what, diff)
	if diff then
		print(string.format("GTE DIFF transfer %s: %s", what, diff))
		ok = false
		return false
	end
	transfers += 1
	return true
end

if ok then
	local TRANSFER_VALUES = {
		0x00000000, 0x00000001, 0x0000007F, 0x00000080, 0x00007FFE, 0x00007FFF,
		0x00008000, 0x00008001, 0x0000FFFE, 0x0000FFFF, 0x00010000, 0x12345678,
		0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
	}
	-- every data register through writeData, then full state and full readback
	for reg = 0, 31 do
		for _, v in ipairs(TRANSFER_VALUES) do
			local real, ref = resetPair()
			real:writeData(reg, v)
			ref:writeData(reg, v)
			local diff = compareState(real, ref)
			if not diff then
				diff = compareReads(real, ref)
			end
			if not checkTransfer(real, ref, string.format("writeData(%d,%08X)", reg, band(v, 0xFFFFFFFF)), diff) then
				break
			end
		end
		if not ok then
			break
		end
	end
end

-- every control register through writeCtrl (the matrix words hold three s16
-- elements, the single-element words sign-extend, and reg 31 is the flag)
if ok then
	for reg = 0, 31 do
		for _, v in ipairs({ 0x00000000, 0x00008000, 0x00007FFF, 0xFFFFFFFF, 0x12345678, 0x80000000, 0x00018000, 0x7FFF7FFF }) do
			local real, ref = resetPair()
			real:writeCtrl(reg, v)
			ref:writeCtrl(reg, v)
			local diff = compareState(real, ref)
			if not diff then
				diff = compareReads(real, ref)
			end
			if not checkTransfer(real, ref, string.format("writeCtrl(%d,%08X)", reg, band(v, 0xFFFFFFFF)), diff) then
				break
			end
		end
		if not ok then
			break
		end
	end
end

-- sxyp fifo push chain: each write shifts the three-stage fifo
if ok then
	local real, ref = resetPair()
	for _, v in ipairs({ 0x11112222, 0x33334444, 0x55556666, 0x77778888, 0x9999AAAA }) do
		real:writeData(15, v)
		ref:writeData(15, v)
		local diff = compareState(real, ref)
		if not diff then
			diff = compareReads(real, ref)
		end
		if not checkTransfer(real, ref, string.format("sxyp push %08X", band(v, 0xFFFFFFFF)), diff) then
			break
		end
	end
end

-- irgb 555 decode into ir1-3 and lzcs-to-lzcr, driven through the transfer
-- methods with the full 32-bit space sampled so every component decodes
if ok then
	local rng = newFuzzRng(0xB0B5EED)
	for caseIndex = 1, 200 do
		local real, ref = resetPair()
		local irgb = band(rng(), 0x7FFF)
		real:writeData(28, irgb)
		ref:writeData(28, irgb)
		local diff = compareState(real, ref)
		if not diff then
			diff = compareReads(real, ref)
		end
		if not checkTransfer(real, ref, string.format("irgb %04X", irgb), diff) then
			break
		end
	end
end

if ok then
	local rng = newFuzzRng(0x1C5C5)
	for caseIndex = 1, 200 do
		local real, ref = resetPair()
		local lz = band(rng(), 0xFFFFFFFF)
		real:writeData(30, lz)
		ref:writeData(30, lz)
		local diff = compareState(real, ref)
		if not diff then
			diff = compareReads(real, ref)
		end
		if not checkTransfer(real, ref, string.format("lzcs %08X", lz), diff) then
			break
		end
	end
end

if ok then
	print(string.format("GTE_DIFF PASS: %d commands and %d register transfers in agreement", executed, transfers))
else
	print("GTE_DIFF FAIL")
end

require("@lune/process").exit(ok and 0 or 1)
