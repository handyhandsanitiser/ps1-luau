-- shared iso9660 disc-image reader for the hosted front-ends (roblox fetches sectors over http
-- from disc_server.py; lune slices a local .bin/.cue).
-- hosts only provide a readSector(lba) callback returning a raw 2352-byte sector (2048-byte user
-- data is accepted) and consume the boot-executable record.

local Disc = {}

local ISO_RAW_SECTOR_SIZE = 2352
local ISO_USER_DATA_SIZE = 2048
local ISO_USER_DATA_OFFSET = 25
local ISO_USER_DATA_OFFSET_ALT = 24

-- little-endian 32-bit read from a binary string; 1-based byte index.
function Disc.readU32LE(data, index)
	local b0 = data:byte(index) or 0
	local b1 = data:byte(index + 1) or 0
	local b2 = data:byte(index + 2) or 0
	local b3 = data:byte(index + 3) or 0
	return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

-- slice the 2048-byte user data out of a raw 2352-byte sector.  a sector that
-- already is user data (2048 bytes) passes through unchanged.
local function sectorUserData(rawSector, userDataOffset)
	if type(rawSector) ~= "string" then
		return nil
	end
	if #rawSector >= ISO_RAW_SECTOR_SIZE then
		local offset = userDataOffset or ISO_USER_DATA_OFFSET
		return rawSector:sub(offset, offset + ISO_USER_DATA_SIZE - 1)
	end
	if #rawSector == ISO_USER_DATA_SIZE then
		return rawSector
	end
	return nil
end

-- concatenate the user data of the sectors [extentLba, extentLba + n), then
-- trim to byteSize.
local function readIsoFile(readSector, extentLba, byteSize, userDataOffset)
	local sectorsToRead = math.ceil(byteSize / ISO_USER_DATA_SIZE)
	local chunks = table.create(sectorsToRead)
	for i = 0, sectorsToRead - 1 do
		local raw = readSector(extentLba + i)
		if not raw then
			return nil
		end
		local user = sectorUserData(raw, userDataOffset)
		if not user then
			return nil
		end
		chunks[i + 1] = user
	end
	return table.concat(chunks):sub(1, byteSize)
end

-- parse the variable-length records of one iso9660 directory extent.
local function parseIsoDirectory(directoryData)
	local records = {}
	local pos = 1
	while pos <= #directoryData do
		local recordLength = directoryData:byte(pos) or 0
		if recordLength == 0 then
			local nextSectorStart = (math.floor((pos - 1) / ISO_USER_DATA_SIZE) + 1) * ISO_USER_DATA_SIZE + 1
			if nextSectorStart <= pos then
				break
			end
			pos = nextSectorStart
		else
			if pos + recordLength - 1 > #directoryData then
				break
			end
			local extentLba = Disc.readU32LE(directoryData, pos + 2)
			local byteSize = Disc.readU32LE(directoryData, pos + 10)
			local flags = directoryData:byte(pos + 25) or 0
			local nameLength = directoryData:byte(pos + 32) or 0
			local name = ""
			if nameLength > 0 then
				name = directoryData:sub(pos + 33, pos + 33 + nameLength - 1)
			end
			table.insert(records, {
				name = name,
				extentLba = extentLba,
				byteSize = byteSize,
				flags = flags,
			})
			pos += recordLength
		end
	end
	return records
end

-- iso9660 names are uppercase and carry a ";1" version suffix.
local function normalizeIsoName(name)
	local normalized = string.upper(name or "")
	normalized = normalized:gsub(";1$", "")
	return normalized
end

local function findRecordByName(records, wantedName)
	local wantedUpper = normalizeIsoName(wantedName)
	for _, record in ipairs(records) do
		local candidate = normalizeIsoName(record.name)
		if candidate == wantedUpper then
			return record
		end
	end
	return nil
end

-- fallback when SYSTEM.CNF is missing or unresolvable: the first non-directory entry that looks like a playstation executable (SLUS_123.45;1 / SCES_123.45;1 / .EXE;1).
local function pickLikelyExeRecord(records)
	for _, record in ipairs(records) do
		local upper = string.upper(record.name or "")
		if bit32.band(record.flags or 0, 0x02) == 0 then
			if upper:find("%.EXE;1", 1, false)
				or upper:match("^SL%u%u[_-]%d+%.%d+;1$")
				or upper:match("^SC%u%u[_-]%d+%.%d+;1$") then
				return record
			end
		end
	end
	return nil
end

-- pull the boot path out of SYSTEM.CNF: the value on the first line whose
-- upper-cased text mentions BOOT, stripped of "cdrom:" and a leading slash.
local function parseBootPathFromSystemCnf(systemCnf)
	for line in string.gmatch(systemCnf or "", "[^\r\n]+") do
		local upper = string.upper(line)
		if upper:find("BOOT", 1, true) then
			local rhs = line:match("=(.*)$")
			if rhs then
				local value = rhs:gsub("^%s+", ""):gsub("%s+$", "")
				value = value:gsub("^cdrom:", "")
				value = value:gsub("^CDROM:", "")
				value = value:gsub("^\\", "")
				return value
			end
		end
	end
	return nil
end

-- locate and load the disc's boot executable: resolve the primary volume descriptor, walk the root
-- directory, follow SYSTEM.CNF's BOOT= line, and fall back to the first plausible executable.
-- returns { name, extentLba, byteSize, data } or nil + error.
function Disc.loadExecutableFromDisc(readSector)
	if type(readSector) ~= "function" then
		return nil, "readSector callback required"
	end

	local pvdRaw = readSector(16)
	if not pvdRaw then
		return nil, "failed to read volume descriptor sector"
	end

	local userDataOffset = ISO_USER_DATA_OFFSET
	local pvd = sectorUserData(pvdRaw, userDataOffset)
	if not pvd or #pvd < ISO_USER_DATA_SIZE or pvd:byte(1) ~= 1 or pvd:sub(2, 6) ~= "CD001" then
		userDataOffset = ISO_USER_DATA_OFFSET_ALT
		pvd = sectorUserData(pvdRaw, userDataOffset)
	end
	if not pvd or #pvd < ISO_USER_DATA_SIZE then
		return nil, "failed to read volume descriptor"
	end
	if pvd:byte(1) ~= 1 or pvd:sub(2, 6) ~= "CD001" then
		return nil, "disc does not look like ISO9660"
	end

	local rootRecordOffset = 157
	local rootExtentLba = Disc.readU32LE(pvd, rootRecordOffset + 2)
	local rootByteSize = Disc.readU32LE(pvd, rootRecordOffset + 10)
	if rootExtentLba <= 0 or rootByteSize <= 0 then
		return nil, "invalid root directory"
	end

	local rootDirectoryData = readIsoFile(readSector, rootExtentLba, rootByteSize, userDataOffset)
	if not rootDirectoryData then
		return nil, "failed to read root directory"
	end
	local rootRecords = parseIsoDirectory(rootDirectoryData)

	local systemCnfRecord = findRecordByName(rootRecords, "SYSTEM.CNF")
	local bootRecord = nil
	if systemCnfRecord then
		local systemCnfData = readIsoFile(readSector, systemCnfRecord.extentLba, systemCnfRecord.byteSize, userDataOffset)
		if systemCnfData then
			local bootPath = parseBootPathFromSystemCnf(systemCnfData)
			if bootPath then
				local leafName = bootPath:match("([^\\/]+)$") or bootPath
				bootRecord = findRecordByName(rootRecords, leafName)
			end
		end
	end

	if not bootRecord then
		bootRecord = pickLikelyExeRecord(rootRecords)
	end
	if not bootRecord then
		return nil, "could not locate boot executable"
	end

	local exeData = readIsoFile(readSector, bootRecord.extentLba, bootRecord.byteSize, userDataOffset)
	if not exeData then
		return nil, "failed to read boot executable"
	end
	if exeData:sub(1, 8) ~= "PS-X EXE" then
		return nil, string.format("boot file %s is not a PS-X EXE", tostring(bootRecord.name))
	end

	return {
		name = bootRecord.name,
		extentLba = bootRecord.extentLba,
		byteSize = bootRecord.byteSize,
		data = exeData,
	}
end

return Disc
