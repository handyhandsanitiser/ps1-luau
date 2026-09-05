-- standalone memory-card model for byte-level checks; it does not import the emulator or any host
-- modules, which keeps card protocol tests independent.
-- api:
-- local card = ref.new(virgin)          -- virgin=true -> all 0xff (unformatted)
-- local rx, ack = card:transfer(txbyte) -- returns reply byte + /ack flag
-- card:format()                         -- duckstation memorycardimage::format
-- card.data                             -- 131072-byte array (index 0-based)

local FRAME_SIZE = 128
local DATA_SIZE = 131072
local ADDRESS_MASK = 0x3FF

local State = {
	Idle = 0,
	Command = 1,
	ReadCardID1 = 2,
	ReadCardID2 = 3,
	ReadAddressMSB = 4,
	ReadAddressLSB = 5,
	ReadACK1 = 6,
	ReadACK2 = 7,
	ReadConfirmAddressMSB = 8,
	ReadConfirmAddressLSB = 9,
	ReadData = 10,
	ReadChecksum = 11,
	ReadEnd = 12,
	WriteCardID1 = 13,
	WriteCardID2 = 14,
	WriteAddressMSB = 15,
	WriteAddressLSB = 16,
	WriteData = 17,
	WriteChecksum = 18,
	WriteACK1 = 19,
	WriteACK2 = 20,
	WriteEnd = 21,
	GetIDCardID1 = 22,
	GetIDCardID2 = 23,
	GetIDACK1 = 24,
	GetIDACK2 = 25,
	GetID1 = 26,
	GetID2 = 27,
	GetID3 = 28,
	GetID4 = 29,
}

local band, bor, lshift, rshift, bxor = bit32.band, bit32.bor, bit32.lshift, bit32.rshift, bit32.bxor

local function trunc8(v)
	return band(v, 0xFF)
end

local Ref = {}
Ref.__index = Ref

function Ref.new(virgin)
	local self = setmetatable({}, Ref)
	self.data = table.create(DATA_SIZE)
	if virgin then
		for i = 0, DATA_SIZE - 1 do self.data[i] = 0xFF end
	else
		self:format()
	end
	self:reset()
	return self
end

-- duckstation memorycard::reset (power-up / system reset).
function Ref:reset()
	self:resetTransferState()
	self.noWriteYet = true
end

-- duckstation memorycard::resettransferstate (select deassert; does not touch
-- the flag bit).
function Ref:resetTransferState()
	self.state = State.Idle
	self.address = 0
	self.sectorOffset = 0
	self.checksum = 0
	self.lastByte = 0
end

-- duckstation memorycardimage::getchecksum (xor of the first 127 bytes of a
-- frame, starting at framestart).
local function frameChecksum(data, s)
	local c = 0
	for i = s, s + FRAME_SIZE - 2 do
		c = bxor(c, data[i])
	end
	return trunc8(c)
end

-- duckstation memorycardimage::format: fill 0xff, write the "mc" header, directory frames 1..15, broken-sector list 16..35, zero 36..62, and copy frame 0 to the write-test frame 63.
function Ref:format()
	local data = self.data
	for i = 0, DATA_SIZE - 1 do data[i] = 0xFF end
	-- header (block 0, frame 0)
	for i = 0, FRAME_SIZE - 1 do data[i] = 0 end
	data[0] = 0x4D -- 'M'
	data[1] = 0x43 -- 'C'
	data[FRAME_SIZE - 1] = frameChecksum(data, 0)
	-- directory frames 1..15 (free)
	for frame = 1, 15 do
		local s = frame * FRAME_SIZE
		for i = s, s + FRAME_SIZE - 2 do data[i] = 0 end
		data[s] = 0xA0
		data[s + 8] = 0xFF -- pointer to next file
		data[s + 9] = 0xFF
		data[s + FRAME_SIZE - 1] = frameChecksum(data, s)
	end
	-- broken sector list 16..35
	for frame = 16, 35 do
		local s = frame * FRAME_SIZE
		for i = s, s + FRAME_SIZE - 2 do data[i] = 0 end
		data[s] = 0xFF
		data[s + 1] = 0xFF
		data[s + 2] = 0xFF
		data[s + 3] = 0xFF
		data[s + 8] = 0xFF
		data[s + 9] = 0xFF
		data[s + FRAME_SIZE - 1] = frameChecksum(data, s)
	end
	-- broken sector replacement data 36..55 and unused 56..62: all zeros
	for frame = 36, 62 do
		local s = frame * FRAME_SIZE
		for i = s, s + FRAME_SIZE - 1 do data[i] = 0 end
	end
	-- write test frame 63 = copy of header frame
	for i = 0, FRAME_SIZE - 1 do
		data[63 * FRAME_SIZE + i] = data[i]
	end
	return self
end

-- duckstation memorycard::transfer(data_in) -> data_out, ack
function Ref:transfer(dataIn)
	local dataOut = 0xFF
	local ack = false
	local st = self.state

	if st == State.Idle then
		-- select device
		if dataIn == 0x81 then
			dataOut = 0xFF
			ack = true
			self.state = State.Command
		end
	elseif st == State.Command then
		-- flag reply: bit3 (no_write_yet) until the first write data byte.
		local flag = self.noWriteYet and 0x08 or 0x00
		if dataIn == 0x52 then
			dataOut, ack, self.state = flag, true, State.ReadCardID1
		elseif dataIn == 0x57 then
			dataOut, ack, self.state = flag, true, State.WriteCardID1
		elseif dataIn == 0x53 then
			dataOut, ack, self.state = flag, true, State.GetIDCardID1
		else
			dataOut, ack, self.state = flag, false, State.Idle
		end
	elseif st == State.ReadCardID1 then
		dataOut, ack, self.state = 0x5A, true, State.ReadCardID2
	elseif st == State.ReadCardID2 then
		dataOut, ack, self.state = 0x5D, true, State.ReadAddressMSB
	elseif st == State.ReadAddressMSB then
		dataOut, ack = 0x00, true
		self.address = band(bor(band(self.address, 0x00FF), lshift(trunc8(dataIn), 8)), ADDRESS_MASK)
		self.state = State.ReadAddressLSB
	elseif st == State.ReadAddressLSB then
		dataOut, ack = self.lastByte, true
		self.address = band(bor(band(self.address, 0xFF00), trunc8(dataIn)), ADDRESS_MASK)
		self.sectorOffset = 0
		self.state = State.ReadACK1
	elseif st == State.ReadACK1 then
		dataOut, ack, self.state = 0x5C, true, State.ReadACK2
	elseif st == State.ReadACK2 then
		dataOut, ack, self.state = 0x5D, true, State.ReadConfirmAddressMSB
	elseif st == State.ReadConfirmAddressMSB then
		dataOut, ack, self.state = trunc8(rshift(self.address, 8)), true, State.ReadConfirmAddressLSB
	elseif st == State.ReadConfirmAddressLSB then
		dataOut, ack = trunc8(self.address), true
		self.state = State.ReadData
	elseif st == State.ReadData then
		local bits = self.data[self.address * FRAME_SIZE + self.sectorOffset]
		if self.sectorOffset == 0 then
			self.checksum = bxor(trunc8(rshift(self.address, 8)), trunc8(self.address), bits)
		else
			self.checksum = bxor(self.checksum, bits)
		end
		dataOut, ack = bits, true
		self.sectorOffset = self.sectorOffset + 1
		if self.sectorOffset == FRAME_SIZE then
			self.state = State.ReadChecksum
			self.sectorOffset = 0
		end
	elseif st == State.ReadChecksum then
		dataOut, ack, self.state = self.checksum, true, State.ReadEnd
	elseif st == State.ReadEnd then
		dataOut, ack, self.state = 0x47, false, State.Idle
	elseif st == State.WriteCardID1 then
		dataOut, ack, self.state = 0x5A, true, State.WriteCardID2
	elseif st == State.WriteCardID2 then
		dataOut, ack, self.state = 0x5D, true, State.WriteAddressMSB
	elseif st == State.WriteAddressMSB then
		dataOut, ack = 0x00, true
		self.address = band(bor(band(self.address, 0x00FF), lshift(trunc8(dataIn), 8)), ADDRESS_MASK)
		self.state = State.WriteAddressLSB
	elseif st == State.WriteAddressLSB then
		dataOut, ack = self.lastByte, true
		self.address = band(bor(band(self.address, 0xFF00), trunc8(dataIn)), ADDRESS_MASK)
		self.sectorOffset = 0
		self.state = State.WriteData
	elseif st == State.WriteData then
		if self.sectorOffset == 0 then
			self.checksum = bxor(trunc8(rshift(self.address, 8)), trunc8(self.address), dataIn)
			self.noWriteYet = false
		else
			self.checksum = bxor(self.checksum, dataIn)
		end
		local offset = self.address * FRAME_SIZE + self.sectorOffset
		self.data[offset] = dataIn
		dataOut, ack = self.lastByte, true
		self.sectorOffset = self.sectorOffset + 1
		if self.sectorOffset == FRAME_SIZE then
			self.state = State.WriteChecksum
			self.sectorOffset = 0
		end
	elseif st == State.WriteChecksum then
		dataOut, ack, self.state = self.lastByte, true, State.WriteACK1
	elseif st == State.WriteACK1 then
		dataOut, ack, self.state = 0x5C, true, State.WriteACK2
	elseif st == State.WriteACK2 then
		dataOut, ack, self.state = 0x5D, true, State.WriteEnd
	elseif st == State.WriteEnd then
		dataOut, ack, self.state = 0x47, false, State.Idle
	elseif st == State.GetIDCardID1 then
		dataOut, ack, self.state = 0x5A, true, State.GetIDCardID2
	elseif st == State.GetIDCardID2 then
		dataOut, ack, self.state = 0x5D, true, State.GetIDACK1
	elseif st == State.GetIDACK1 then
		dataOut, ack, self.state = 0x5C, true, State.GetIDACK2
	elseif st == State.GetIDACK2 then
		dataOut, ack, self.state = 0x5D, true, State.GetID1
	elseif st == State.GetID1 then
		dataOut, ack, self.state = 0x04, true, State.GetID2
	elseif st == State.GetID2 then
		dataOut, ack, self.state = 0x00, true, State.GetID3
	elseif st == State.GetID3 then
		dataOut, ack, self.state = 0x00, true, State.GetID4
	elseif st == State.GetID4 then
		dataOut, ack, self.state = 0x80, false, State.Idle
	end

	self.lastByte = dataIn
	return dataOut, ack
end

return Ref
