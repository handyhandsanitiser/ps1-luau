-- fixed-seed xorshift32 used by the differential harnesses (cpu_diff, gpu_diff,
-- gte_diff).  deterministic per seed so a regression reproduces; kept in one
-- place so the three fuzzers can never drift apart.
local band = bit32.band
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

return function(seed)
	local state = band(seed, 0xFFFFFFFF)
	if state == 0 then
		state = 0x6D2B79F5
	end
	return function()
		state = bxor(state, lshift(state, 13))
		state = bxor(state, rshift(state, 17))
		state = bxor(state, lshift(state, 5))
		return band(state, 0xFFFFFFFF)
	end
end