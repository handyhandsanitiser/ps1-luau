local Util = require(script.Parent.Util)

local PSXExe = {}

local band = bit32.band

local HEADER_SIZE = 0x800
local MAGIC = "PS-X EXE"

local function readU32LE(data, offset)
	return Util.readU32LE(data, offset)
end

function PSXExe.parse(data)
	assert(type(data) == "string", "PSXExe.parse expects a binary string")
	assert(#data >= HEADER_SIZE, "PS-X EXE is missing its 0x800-byte header")
	assert(data:sub(1, 8) == MAGIC, "invalid PS-X EXE magic")

	local header = {
		entryPoint = readU32LE(data, 0x11),
		initialGp = readU32LE(data, 0x15),
		loadAddress = readU32LE(data, 0x19),
		fileSize = readU32LE(data, 0x1D),
		dataStart = readU32LE(data, 0x21),
		dataSize = readU32LE(data, 0x25),
		bssAddress = readU32LE(data, 0x29),
		bssSize = readU32LE(data, 0x2D),
		stackBase = readU32LE(data, 0x31),
		stackOffset = readU32LE(data, 0x35),
	}

	-- duckstation injectexecutable: copy exactly min(buffer_size - 0x800, file_size) bytes; a zero file_size loads nothing.
	local payloadSize = math.min(math.max(0, #data - HEADER_SIZE), header.fileSize or 0)
	header.payload = data:sub(HEADER_SIZE + 1, HEADER_SIZE + payloadSize)

	return header
end

-- duckstation injectexecutable: sp = initial_sp_base + initial_sp_offset; when that sum is 0 the loader leaves sp/fp untouched ("use the caller's stack", psx-spx).
function PSXExe.normalizeStackPointer(header)
	local sp = band((header.stackBase or 0) + (header.stackOffset or 0), 0xFFFFFFFF)
	if sp == 0 then
		return nil
	end
	return sp
end

function PSXExe.buildInitialRegisters(header)
	local stackPointer = PSXExe.normalizeStackPointer(header)

	return {
		pc = header.entryPoint,
		gp = header.initialGp or 0,
		sp = stackPointer,
		fp = stackPointer,
		-- psx-spx: "two parameter values are passed to the executable (in r4
		-- and r5 registers)... usually that values are simply r4=1 and r5=0".
		a0 = 1,
		a1 = 0,
		a2 = 0,
		a3 = 0,
	}
end

function PSXExe.loadIntoMemory(memory, data)
	local header = PSXExe.parse(data)

	-- duckstation order: zero the memfill/bss region first, then copy the payload (a payload overlapping the fill wins).
	if (header.bssSize or 0) > 0 then		local address = band(header.bssAddress or 0, 0xFFFFFFFF)
		local remaining = header.bssSize
		while remaining >= 4 do
			memory:write32(address, 0)
			address = band(address + 4, 0xFFFFFFFF)
			remaining -= 4
		end
		while remaining > 0 do
			memory:write8(address, 0)
			address = band(address + 1, 0xFFFFFFFF)
			remaining -= 1
		end
	end

	if header.payload and #header.payload > 0 then
		memory:writeBytes(header.loadAddress, header.payload)
	end

	return header
end

return PSXExe