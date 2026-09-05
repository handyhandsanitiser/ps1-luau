-- duckstation-derived reference for the sio0 controller + multitap devices (port of
-- analog_controller.cpp and multitap.cpp) -- the exact byte/state semantics the emulator's
-- joypad/card state machine must match.
-- api:
-- local pad = padref.analogcontroller.new()
-- local ok, rx = pad:transfer(tx_byte)              -- rx = reply byte, ok = ack
-- local tap = padref.multitap.new(port_index, pada, padb, padc, padd)
-- local ok, rx = tap:transfer(tx_byte)
-- local ok, rx = tap:transfermemorycardslot(slot, tx) -- card slot (0x8n)

local PadRef = {}

local band = bit32.band
local bor = bit32.bor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift

local function trunc8(v) return band(v, 0xFF) end

local SmallMotor = 0
local LargeMotor = 1

-- analogcontroller (duckstation analog_controller.cpp transfer)

local Command = {
	Idle = 0,
	Ready = 1,
	ReadPad = 2,        -- 0x42
	ConfigModeSetMode = 3, -- 0x43
	SetAnalogMode = 4,  -- 0x44
	GetAnalogMode = 5,  -- 0x45
	Command46 = 6,      -- 0x46
	Command47 = 7,      -- 0x47
	Command4C = 8,      -- 0x4C
	GetSetRumble = 9,   -- 0x4D
}

local AnalogController = {}
AnalogController.__index = AnalogController

function AnalogController.new()
	local self = setmetatable({}, AnalogController)
	self.command = Command.Idle
	self.command_step = 0
	self.response_length = 1
	self.rx_buffer = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.tx_buffer = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.configuration_mode = false
	self.analog_mode = false
	self.dualshock_enabled = false
	self.analog_locked = false
	self.status_byte = 0x5A
	self.digital_mode_extra_halfwords = 0
	self.rumble_config = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
	self.motor_state = { 0, 0 }
	self.buttons = 0 -- pressed bit = 1; emulator convention: 0 = nothing pressed
	return self
end

function AnalogController:getResponseNumHalfwords()
	if self.configuration_mode or self.analog_mode then
		return 0x3
	end
	return 0x1 + self.digital_mode_extra_halfwords
end

function AnalogController:getModeID()
	if self.configuration_mode then return 0xF end
	if self.analog_mode then return 0x7 end
	return 0x4
end

function AnalogController:getIDByte()
	return trunc8(bor(lshift(self:getModeID(), 4), self:getResponseNumHalfwords()))
end

function AnalogController:resetRumbleConfig()
	for i = 1, 6 do self.rumble_config[i] = 0xFF end
	self.motor_state[SmallMotor + 1] = 0
	self.motor_state[LargeMotor + 1] = 0
end

function AnalogController:poll()
	self.tx_buffer[1] = self:getIDByte()
	self.tx_buffer[2] = self.status_byte
	local bLo = band(bnot(self.buttons), 0xFF)
	local bHi = band(rshift(bnot(self.buttons), 8), 0xFF)
	self.tx_buffer[3] = bLo
	self.tx_buffer[4] = bHi
	if self.analog_mode or self.configuration_mode then
		-- centered axes (silent hill never drives the sticks)
		self.tx_buffer[5] = 0x80
		self.tx_buffer[6] = 0x80
		self.tx_buffer[7] = 0x80
		self.tx_buffer[8] = 0x80
	else
		self.tx_buffer[5] = 0
		self.tx_buffer[6] = 0
		self.tx_buffer[7] = 0
		self.tx_buffer[8] = 0
	end
end

function AnalogController:setMotorState(motor, value)
	self.motor_state[motor + 1] = value
end

-- analogcontroller::resettransferstate: called when joy_ctrl.select deasserts between transactions -- back to idle, unread reply bytes dropped (this truncates an 8-byte config-mode reply); config/analog mode persist.
function AnalogController:resetTransferState()
	self.command = Command.Idle
	self.command_step = 0
end

-- returns (ack, rx_byte) like duckstation analogcontroller::transfer: the command byte is consumed in ready state, then each byte streams tx_buffer[command_step]; ack = (command_step ~= 0).
function AnalogController:transfer(data_in)
	self.rx_buffer[self.command_step + 1] = data_in

	if self.command == Command.Idle then
		self.tx_buffer[1] = 0xFF
		if data_in == 0x01 then
			self.command_step = 0
			self.response_length = 1
			self.command = Command.Ready
			return true, 0xFF
		end
		return false, 0xFF
	end

	if self.command == Command.Ready then
		-- command byte arrives: set up the reply and enter the command state (duckstation streams tx_buffer[0] as the reply to this same byte).
		if data_in == 0x42 then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.ReadPad
			self:poll()
		elseif data_in == 0x43 then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.ConfigModeSetMode
			if not self.configuration_mode then
				self:poll()
			else
				self.tx_buffer[1] = self:getIDByte()
				self.tx_buffer[2] = self.status_byte
				for i = 3, 8 do self.tx_buffer[i] = 0 end
			end
		elseif self.configuration_mode and data_in == 0x44 then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.SetAnalogMode
			self.tx_buffer[1] = self:getIDByte()
			self.tx_buffer[2] = self.status_byte
			for i = 3, 8 do self.tx_buffer[i] = 0 end
			self:resetRumbleConfig()
		elseif self.configuration_mode and data_in == 0x45 then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.GetAnalogMode
			self.tx_buffer[1] = self:getIDByte()
			self.tx_buffer[2] = self.status_byte
			self.tx_buffer[3] = 0x01 -- Typ
			self.tx_buffer[4] = 0x02 -- Num
			self.tx_buffer[5] = self.analog_mode and 1 or 0 -- Led (current mode)
			self.tx_buffer[6] = 0x02 -- Act
			self.tx_buffer[7] = 0x01 -- Com
			self.tx_buffer[8] = 0x00
		elseif self.configuration_mode and data_in == 0x46 then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.Command46
			self.tx_buffer[1] = self:getIDByte()
			self.tx_buffer[2] = self.status_byte
			for i = 3, 8 do self.tx_buffer[i] = 0 end
		elseif self.configuration_mode and data_in == 0x47 then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.Command47
			self.tx_buffer[1] = self:getIDByte()
			self.tx_buffer[2] = self.status_byte
			self.tx_buffer[3] = 0x00
			self.tx_buffer[4] = 0x00
			self.tx_buffer[5] = 0x02
			self.tx_buffer[6] = 0x00
			self.tx_buffer[7] = 0x01
			self.tx_buffer[8] = 0x00
		elseif self.configuration_mode and data_in == 0x4C then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.Command4C
			self.tx_buffer[1] = self:getIDByte()
			self.tx_buffer[2] = self.status_byte
			for i = 3, 8 do self.tx_buffer[i] = 0 end
		elseif self.configuration_mode and data_in == 0x4D then
			self.command_step = 0
			self.response_length = (self:getResponseNumHalfwords() + 1) * 2
			self.command = Command.GetSetRumble
			self.tx_buffer[1] = self:getIDByte()
			self.tx_buffer[2] = self.status_byte
			for i = 3, 8 do self.tx_buffer[i] = 0 end
		else
			return false, 0xFF
		end
		-- fall through to stream the reply for this byte
	end

	-- per-command processing of the current data byte.
	if self.command == Command.ReadPad then
		if not self.dualshock_enabled and self.command_step == 3 then
			local legacy_rumble = band(self.rx_buffer[3], 0xC0) == 0x40 and band(self.rx_buffer[4], 0x01) ~= 0
			self:setMotorState(SmallMotor, legacy_rumble and 255 or 0)
		end
	elseif self.command == Command.ConfigModeSetMode then
		if self.command_step == self.response_length - 1 then
			self.configuration_mode = self.rx_buffer[3] == 1
			if self.configuration_mode then
				self.dualshock_enabled = true
				self.status_byte = 0x5A
			end
		end
	elseif self.command == Command.SetAnalogMode then
		if self.command_step == 2 then
			local v = data_in
			if v == 0x00 or v == 0x01 then
				self.analog_mode = (v == 0x01)
				if self.dualshock_enabled and not self.analog_mode then
					self.status_byte = 0x00
				end
			end
		elseif self.command_step == 3 then
			local v = data_in
			if v == 0x02 or v == 0x03 then
				self.analog_locked = (v == 0x03)
			end
		end
	elseif self.command == Command.Command46 then
		if self.command_step == 2 then
			if data_in == 0x00 then
				self.tx_buffer[5] = 0x01
				self.tx_buffer[6] = 0x02
				self.tx_buffer[7] = 0x00
				self.tx_buffer[8] = 0x0A
			elseif data_in == 0x01 then
				self.tx_buffer[5] = 0x01
				self.tx_buffer[6] = 0x01
				self.tx_buffer[7] = 0x01
				self.tx_buffer[8] = 0x14
			end
		end
	elseif self.command == Command.Command47 then
		if self.command_step == 2 and data_in ~= 0x00 then
			self.tx_buffer[5] = 0x00
			self.tx_buffer[6] = 0x00
			self.tx_buffer[7] = 0x00
			self.tx_buffer[8] = 0x00
		end
	elseif self.command == Command.Command4C then
		if self.command_step == 2 then
			if data_in == 0x00 then
				self.tx_buffer[6] = 0x04
			elseif data_in == 0x01 then
				self.tx_buffer[6] = 0x07
			end
		end
	elseif self.command == Command.GetSetRumble then
		if self.command_step >= 2 and self.command_step < 7 then
			local index = self.command_step - 2 + 1
			self.tx_buffer[self.command_step + 1] = self.rumble_config[index]
			self.rumble_config[index] = data_in
		elseif self.command_step == 7 then
			local has_small = false
			local has_large = false
			for i = 1, 6 do
				has_small = has_small or (self.rumble_config[i] == SmallMotor)
				has_large = has_large or (self.rumble_config[i] == LargeMotor)
			end
			if not has_small then self:setMotorState(SmallMotor, 0) end
			if not has_large then self:setMotorState(LargeMotor, 0) end
		end
	end

	-- stream the reply for this byte and advance.
	local rx = self.tx_buffer[self.command_step + 1]
	self.command_step = (self.command_step + 1) % self.response_length
	local ack = (self.command_step ~= 0)
	if self.command_step == 0 then
		self.command = Command.Idle
		for i = 1, 8 do self.rx_buffer[i] = 0 end
		for i = 1, 8 do self.tx_buffer[i] = 0 end
	end
	return ack, rx
end

PadRef.AnalogController = AnalogController

-- multitap (duckstation multitap.cpp transfer)

local Multitap = {}
Multitap.__index = Multitap

local TransferState = {
	Idle = 0,
	MemoryCard = 1,
	ControllerCommand = 2,
	SingleController = 3,
	AllControllers = 4,
}

function Multitap.new(portIndex, pads)
	-- pads = { pad_for_slot_1, ..., pad_for_slot_4 } (analogcontroller instances)
	local self = setmetatable({}, Multitap)
	self.portIndex = portIndex or 0
	self.pads = pads or {}
	self.transfer_state = TransferState.Idle
	self.selected_slot = 0
	self.controller_transfer_step = 0
	self.transfer_all_controllers = false
	self.invalid_transfer_all_command = false
	self.current_controller_done = false
	self.transfer_buffer = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
	return self
end

function Multitap:getMultitapIDByte()
	-- 0x20 | (port) : duckstation getmultitapidbyte
	return 0x20 + self.portIndex
end

function Multitap:getStatusByte()
	return 0x5A
end

function Multitap:transferController(slot, data_in)
	local pad = self.pads[slot]
	if not pad then return false, 0xFF end
	return pad:transfer(data_in)
end

-- card slots are not part of this ref (the emulator's card side is validated
-- separately against psx-spx); a card transfer returns 0xff no-ack.
function Multitap:transferMemoryCard(slot, data_in)
	return false, 0xFF
end

-- returns (ack, rx_byte).
function Multitap:transfer(data_in)
	local ack = false
	local data_out = 0xFF

	if self.transfer_state == TransferState.Idle then
		local slotBit = band(data_in, 0x0F)
		if data_in >= 0x81 and data_in <= 0x84 then
			self.selected_slot = slotBit - 1
			ack, data_out = self:transferMemoryCard(self.selected_slot, 0x81)
			if ack then self.transfer_state = TransferState.MemoryCard end
		elseif data_in >= 0x01 and data_in <= 0x04 then
			self.selected_slot = data_in - 1
			ack, data_out = self:transferController(self.selected_slot, 0x01)
			if ack then
				self.transfer_state = TransferState.ControllerCommand
				if self.transfer_all_controllers then
					for i = 0, 3 do
						if i ~= self.selected_slot then
							self:transferController(i, 0x01)
						end
					end
				end
			end
		else
			data_out = 0xFF
			ack = false
		end
	elseif self.transfer_state == TransferState.MemoryCard then
		ack, data_out = self:transferMemoryCard(self.selected_slot, data_in)
		if not ack then self.transfer_state = TransferState.Idle end
	elseif self.transfer_state == TransferState.ControllerCommand then
		if self.controller_transfer_step == 0 then
			if self.transfer_all_controllers then
				data_out = self:getMultitapIDByte()
				self.invalid_transfer_all_command = (data_in ~= 0x42)
				ack = true
			else
				ack, data_out = self:transferController(self.selected_slot, data_in)
			end
			self.controller_transfer_step = self.controller_transfer_step + 1
		elseif self.controller_transfer_step == 1 then
			if self.transfer_all_controllers then
				data_out = self:getStatusByte()
				ack = not self.invalid_transfer_all_command
				self.selected_slot = 0
				self.transfer_state = TransferState.AllControllers
			else
				ack, data_out = self:transferController(self.selected_slot, 0x00)
				self.transfer_state = TransferState.SingleController
			end
			self.transfer_all_controllers = band(data_in, 0x01) == 1
			self.controller_transfer_step = 0
		end
	elseif self.transfer_state == TransferState.SingleController then
		ack, data_out = self:transferController(self.selected_slot, data_in)
		if not ack then self.transfer_state = TransferState.Idle end
	elseif self.transfer_state == TransferState.AllControllers then
		data_out = self.transfer_buffer[self.controller_transfer_step + 1]
		ack = true
		if self.current_controller_done then
			self.transfer_buffer[self.controller_transfer_step + 1] = 0xFF
		else
			local newAck
			newAck, self.transfer_buffer[self.controller_transfer_step + 1] =
				self:transferController(self.selected_slot, data_in)
			self.current_controller_done = not newAck
		end
		self.controller_transfer_step = self.controller_transfer_step + 1
		if self.controller_transfer_step % 8 == 0 then
			self.current_controller_done = false
			self.selected_slot = (self.selected_slot + 1) % 4
			if self.selected_slot == 0 then ack = false end
		end
	end

	return ack, data_out
end

PadRef.Multitap = Multitap

return PadRef
