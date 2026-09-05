-- console region detection: ntsc (3413 dots/line x 263 lines) vs pal (3406 x 314).  duckstation
-- identifies the region by md5 of the bios image; this module transcribes its bios.cpp table.
-- the pure-luau md5 lives in Util.luau (tools/md5.luau delegates to it).
-- returns "ntsc" / "pal", or nil when the image isn't in the table (callers fall back to the default).

local Util = require(script.Parent.Util)
local Region = {}

-- duckstation bios.cpp s_bios_table (hash -> region).  ntsc-j and ntsc-u are
-- both 59.94hz; the emulator only needs the pal/ntsc split for timing.
local BIOS_REGIONS = {
	-- ntsc-j
	["239665b1a3dade1b5a52c06338011044"] = "ntsc",
	["ca5cfc321f916756e3f0effbfaeba13b"] = "ntsc",
	["849515939161e62f6b866f6853006780"] = "ntsc",
	["cba733ceeff5aef5c32254f1d617fa62"] = "ntsc",
	["57a06303dfa9cf9351222dfcbb4a29d9"] = "ntsc",
	["8dd7d5296a650fac7319bce665a6a53c"] = "ntsc",
	["8e4c14f567745eff2f0408c8129f72a6"] = "ntsc",
	["b84be139db3ee6cbd075630aa20a6553"] = "ntsc",
	["8abc1b549a4a80954addc48ef02c4521"] = "ntsc",
	["f63bc530bd7ad7c026fcd6f7bd0d9525"] = "ntsc",
	["cee06bd68c333fc5768244eae77e4495"] = "ntsc",
	["bb6bbc850458fff08af30e969ffd0175"] = "ntsc",
	["815ac991d8bc3b364696bead3457de7d"] = "ntsc",
	-- ntsc-u
	["924e392ed05558ffdb115408c263dccf"] = "ntsc",
	["dc2b9bf8da62ec93e868cfd29f0d067d"] = "ntsc",
	["da27e8b6dab242d8f91a9b25d80c63b8"] = "ntsc",
	["490f666e1afb15b7362b406ed1cea246"] = "ntsc",
	["1e68c231d0896b7eadcad1d7d8e76129"] = "ntsc",
	["9a09ab7e49b422c007e6d54d7c49b965"] = "ntsc",
	["6e3735ff4c7dc899ee98981385f6f3d0"] = "ntsc",
	["63e6fd9b3c72e0d7b920e80cf76645cd"] = "ntsc",
	["a20c97c02210f16678ca3010127caf36"] = "ntsc",
	["8db2fbbac7413bf3e7154c1e0715e565"] = "ntsc",
	["0bf988e9c7aaa4c051805b0fa6eb3387"] = "ntsc",
	["8accc3c49ac45f5ae2c5db0adc854633"] = "ntsc",
	["b107b5710042abe887c0f6175f6e94bb"] = "ntsc",
	-- pal
	["54847e693405ffeb0359c6287434cbef"] = "pal",
	["417b34706319da7cf001e76e40136c23"] = "pal",
	["e2110b8a2b97a8e0b857a45d32f7e187"] = "pal",
	["32736f17079d0b2b7024407c39bd3050"] = "pal",
	["b9d9a0286c33dc6b7237bb13cd46fdee"] = "pal",
	["b10f5e0e3d9eb60e5159690680b1e774"] = "pal",
	["de93caec13d1a141a40a79f5c86168d6"] = "pal",
	["91c87cb2f2eb6ce529a2360f80ce2457"] = "pal",
	["3016b3dd42148a67e2c048595ca4d7ce"] = "pal",
	["b7fa11e87d51752a98b38e3e691cbf17"] = "pal",
	["6f9a6feb749f0533aaae2cc45090b0ed"] = "pal",
	["838544f12de9b0abc90811279ee223c8"] = "pal",
}

-- - Detect the console region from BIOS ROM bytes.
-- @return "ntsc" | "pal" | nil  (nil = unknown image)
function Region.detect(romBytes)
	if type(romBytes) ~= "string" or #romBytes == 0 then
		return nil
	end
	return BIOS_REGIONS[Util.md5(romBytes)]
end

return Region
