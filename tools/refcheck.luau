-- constant-level drift check between the emulator core and the reference models.  the tools/*_ref
-- files are independent implementations; this guards the cheapest and most factual layer -- the
-- named constants both sides declare, in local or module-table form.  a shared name with different
-- values is drift; a pair with no shared names fails rather than passing silently (coverage cannot
-- quietly shrink to zero); a missing ref pair is an unguarded component.
--
-- usage: lune run tools/refcheck.luau   (or via tools/run.luau refcheck)

local fs = require("@lune/fs")
local process = require("@lune/process")

local PAIRS = {
	{ core = "CPU", ref = "cpu_ref" },
	{ core = "Memory", ref = "mem_ref" },
	{ core = "DMA", ref = "dma_ref" },
	{ core = "GPU", ref = "gpu_ref" },
	{ core = "CDROM", ref = "cdrom_ref" },
	{ core = "SPU", ref = "spu_ref" },
	{ core = "GTE", ref = "gte_ref" },
	{ core = "MDEC", ref = "mdec_ref" },
	{ core = "Timers", ref = "timers_ref" },
}

-- constants appear as locals ("local NAME = <literal>") or module-table fields ("Memory.RAM_SIZE =
-- <literal>"); both count, or a module that stores its map on its own table (Memory) is invisible.
-- lua patterns have no alternation, so each style gets its own pattern.
local LOCAL_HEX = "local%s+([A-Z][A-Z0-9_]+)%s*=%s*0x(%x+)"
local LOCAL_DEC = "local%s+([A-Z][A-Z0-9_]+)%s*=%s*(%d+)"
local TABLE_HEX = "([A-Z][A-Za-z0-9_]*)%.([A-Z][A-Z0-9_]+)%s*=%s*0x(%x+)"
local TABLE_DEC = "([A-Z][A-Za-z0-9_]*)%.([A-Z][A-Z0-9_]+)%s*=%s*(%d+)"

local function valuesText(values)
	local parts = {}
	for value in pairs(values) do
		parts[#parts + 1] = string.format("0x%X", value)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function collectConstants(source)
	local byName = {}
	local function add(name, digits, base)
		local value = tonumber(digits, base)
		if value ~= nil then
			-- a name may be declared more than once (e.g. per-mode tables);
			-- record every distinct value.
			byName[name] = byName[name] or {}
			byName[name][value] = true
		end
	end
	for name, digits in string.gmatch(source, LOCAL_HEX) do
		add(name, digits, 16)
	end
	for name, digits in string.gmatch(source, LOCAL_DEC) do
		add(name, digits, 10)
	end
	for _, name, digits in string.gmatch(source, TABLE_HEX) do
		add(name, digits, 16)
	end
	for _, name, digits in string.gmatch(source, TABLE_DEC) do
		add(name, digits, 10)
	end
	return byName
end

local function corePath(name)
	return "src/shared/PS1/" .. name .. ".luau"
end

local function refPath(name)
	return "tools/" .. name .. ".luau"
end

local function loadFile(path)
	local ok, source = pcall(function()
		return fs.readFile(path)
	end)
	if not ok then
		return nil
	end
	return source
end

local mismatches = 0
local pairsChecked = 0
local totalShared = 0

for _, pair in ipairs(PAIRS) do
	local coreSource = loadFile(corePath(pair.core))
	if not coreSource then
		print(string.format("FAIL missing core module: %s", corePath(pair.core)))
		mismatches += 1
	else
		local refSource = loadFile(refPath(pair.ref))
		if not refSource then
			print(string.format("FAIL %s has no reference model: %s", pair.core, refPath(pair.ref)))
			mismatches += 1
		else
			local coreConsts = collectConstants(coreSource)
			local refConsts = collectConstants(refSource)
			local shared = 0
			local pairMismatches = 0
			for name, coreValues in pairs(coreConsts) do
				local refValues = refConsts[name]
				if refValues then
					shared += 1
					local same = true
					for value in pairs(coreValues) do
						if not refValues[value] then
							same = false
						end
					end
					if not same then
						pairMismatches += 1
						print(string.format(
							"FAIL %s.%s differs: core=%s ref=%s",
							pair.core,
							name,
							valuesText(coreValues),
							valuesText(refValues)
						))
					end
				end
			end
			pairsChecked += 1
			totalShared += shared
			if pairMismatches == 0 then
				if shared == 0 then
					-- an empty comparison is a silent pass for an unguarded pair; treat it as a failure so coverage can never quietly shrink to zero.
					pairMismatches = 1
					print(string.format(
						"FAIL %s vs %s: unguarded pair, 0 shared constant names between core and ref",
						pair.core, pair.ref
					))
				else
					print(string.format("ok   %s vs %s (%d shared constants agree)", pair.core, pair.ref, shared))
				end
			end
			mismatches += pairMismatches
		end
	end
end

if mismatches > 0 then
	print(string.format("REFCHECK FAIL: %d problem(s) across %d pair(s)", mismatches, pairsChecked))
else
	print(string.format("REFCHECK PASS: %d pair(s), %d shared constants in agreement", pairsChecked, totalShared))
end

process.exit(mismatches > 0 and 1 or 0)
