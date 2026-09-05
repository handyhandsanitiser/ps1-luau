-- slice a whole .bin into fixed-size sector reads for the lune front-ends.
-- shared by tools/lib/boot.luau (fixed 2352) and tools/lune_boot_ps1.luau
-- (cue-inferred size) so the bounds/padding logic lives in one place.
local DiscBin = {}

-- returns a readSector(lba) closure over binData plus the sector count.
-- a short final sector is zero-padded (real drives deliver full sectors).
function DiscBin.reader(binData, sectorSize)
	local sectorCount = math.floor(#binData / sectorSize)
	local function readSector(lba)
		if lba < 0 then return nil end
		local start = (lba * sectorSize) + 1
		if start > #binData then return nil end
		local chunk = binData:sub(start, math.min(start + sectorSize - 1, #binData))
		if #chunk < sectorSize then
			chunk ..= string.rep("\0", sectorSize - #chunk)
		end
		return chunk
	end
	return readSector, sectorCount
end

return DiscBin