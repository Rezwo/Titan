--!strict
local EncodingService = game:GetService("EncodingService")

local MemoryBufferPool : { buffer } = {}
local PoolCapacity : number = 50
local InitialBufferSize : number = 4096
local BinaryVersion : number = 1

for BufferIndex : number = 1, PoolCapacity do
	MemoryBufferPool[BufferIndex] = buffer.create(InitialBufferSize)
end

local function AcquireBuffer() : buffer
	local AvailableBuffer : buffer? = table.remove(MemoryBufferPool)
	return AvailableBuffer or buffer.create(InitialBufferSize)
end

local function ReleaseBuffer(UsedBuffer : buffer)
	if #MemoryBufferPool >= PoolCapacity then
		return
	end
	if buffer.len(UsedBuffer) > 1048576 then
		table.insert(MemoryBufferPool, buffer.create(InitialBufferSize))
	else
		table.insert(MemoryBufferPool, UsedBuffer)
	end
end

local function EnsureBufferCapacity(WorkingBuffer : buffer, CursorPosition : number, BytesToAdd : number) : buffer
	local RequiredSize : number = CursorPosition + BytesToAdd
	local CurrentSize : number = buffer.len(WorkingBuffer)

	if RequiredSize > CurrentSize then
		local NewSize : number = CurrentSize * 2
		while NewSize < RequiredSize do
			NewSize = NewSize * 2
		end

		local NewBuffer : buffer = buffer.create(NewSize)
		buffer.copy(NewBuffer, 0, WorkingBuffer, 0, CurrentSize)
		return NewBuffer
	end
	return WorkingBuffer
end

type Instruction = {
	Key : string,
	DataType : "UInt8" | "UInt16" | "UInt32" | "Float64" | "Boolean" | "String" | "Dictionary" | "List",
	Children : { Instruction }?
}

local TitanBinary = {}
local InstructionCache : { [string] : { Instruction } } = {}

local function CompileSchemaRecursive(SchemaDefinition : any) : { Instruction }
	local InstructionList : { Instruction } = {}
	local Keys : { string } = {}

	for SchemaKey : string, _ : any in SchemaDefinition do
		table.insert(Keys, SchemaKey)
	end
	table.sort(Keys)

	for KeyIndex : number, SchemaKey : string in Keys do
		local SchemaItem : any = SchemaDefinition[SchemaKey]
		local TypeTag : string = (type(SchemaItem) == "table" and SchemaItem._Type) or ""
		local NewInstruction : Instruction = {
			Key = SchemaKey,
			DataType = "String",
			Children = nil
		}

		if TypeTag == "UInt8" then
			NewInstruction.DataType = "UInt8"
		elseif TypeTag == "UInt16" then
			NewInstruction.DataType = "UInt16"
		elseif TypeTag == "UInt32" or TypeTag == "Integer" then
			NewInstruction.DataType = "UInt32"
		elseif TypeTag == "Float64" or TypeTag == "Number" then
			NewInstruction.DataType = "Float64"
		elseif TypeTag == "Boolean" then
			NewInstruction.DataType = "Boolean"
		elseif TypeTag == "Dictionary" then
			NewInstruction.DataType = "Dictionary"
			NewInstruction.Children = CompileSchemaRecursive(SchemaItem._Structure or SchemaItem._Default)
		elseif TypeTag == "List" then
			NewInstruction.DataType = "List"
			local ContentInstruction : Instruction = CompileSchemaRecursive({ ["_Item"] = SchemaItem._ContentType })[1]
			NewInstruction.Children = { ContentInstruction }
		else
			NewInstruction.DataType = "String"
		end
		table.insert(InstructionList, NewInstruction)
	end
	return InstructionList
end

function TitanBinary.CompileSchema(StoreName : string, SchemaTemplate : any)
	InstructionCache[StoreName] = CompileSchemaRecursive(SchemaTemplate)
end

local function CollectInternedStrings(Data : any, InstructionList : { Instruction }, StringMap : { [string] : number }, StringList : { string })
	for InstructionIndex : number, Item : Instruction in InstructionList do
		local Value : any = Data[Item.Key]

		if Item.DataType == "String" then
			local StringValue : string = (type(Value) == "string") and Value or tostring(Value or "")
			if not StringMap[StringValue] then
				local NewIndex : number = #StringList + 1
				StringList[NewIndex] = StringValue
				StringMap[StringValue] = NewIndex
			end
		elseif Item.DataType == "Dictionary" and Item.Children then
			CollectInternedStrings(Value or {}, Item.Children, StringMap, StringList)
		elseif Item.DataType == "List" and Item.Children then
			local ListTable : { any } = (type(Value) == "table") and Value or {}
			local ContentType : string = Item.Children[1].DataType

			if ContentType == "String" or ContentType == "Dictionary" or ContentType == "List" then
				for _, ListItem : any in ipairs(ListTable) do
					CollectInternedStrings({ ["_Item"] = ListItem }, Item.Children, StringMap, StringList)
				end
			end
		end
	end
end

local PackDataToBuffer : (any, { Instruction }, buffer, number, { [string] : number }) -> (buffer, number)
local UnpackDataFromBuffer : ({ Instruction }, buffer, number, { string }) -> (any, number)

PackDataToBuffer = function(Data : any, InstructionList : { Instruction }, WorkingBuffer : buffer, CursorPosition : number, StringMap : { [string] : number }) : (buffer, number)
	for InstructionIndex : number, Item : Instruction in InstructionList do
		local Value : any = Data[Item.Key]

		if Item.DataType == "UInt8" then
			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 1)
			buffer.writeu8(WorkingBuffer, CursorPosition, Value or 0)
			CursorPosition += 1
		elseif Item.DataType == "UInt16" then
			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 2)
			buffer.writeu16(WorkingBuffer, CursorPosition, Value or 0)
			CursorPosition += 2
		elseif Item.DataType == "UInt32" then
			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 4)
			buffer.writeu32(WorkingBuffer, CursorPosition, Value or 0)
			CursorPosition += 4
		elseif Item.DataType == "Float64" then
			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 8)
			buffer.writef64(WorkingBuffer, CursorPosition, Value or 0)
			CursorPosition += 8
		elseif Item.DataType == "Boolean" then
			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 1)
			buffer.writeu8(WorkingBuffer, CursorPosition, Value and 1 or 0)
			CursorPosition += 1
		elseif Item.DataType == "String" then
			local StringValue : string = (type(Value) == "string") and Value or tostring(Value or "")
			local StringIndex : number = StringMap[StringValue] or 0
			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 4)
			buffer.writeu32(WorkingBuffer, CursorPosition, StringIndex)
			CursorPosition += 4
		elseif Item.DataType == "Dictionary" and Item.Children then
			WorkingBuffer, CursorPosition = PackDataToBuffer(Value or {}, Item.Children, WorkingBuffer, CursorPosition, StringMap)
		elseif Item.DataType == "List" and Item.Children then
			local ListTable : { any } = (type(Value) == "table") and Value or {}
			local Count : number = #ListTable

			WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 4)
			buffer.writeu32(WorkingBuffer, CursorPosition, Count)
			CursorPosition += 4

			for _, ListItem : any in ipairs(ListTable) do
				WorkingBuffer, CursorPosition = PackDataToBuffer({ ["_Item"] = ListItem }, Item.Children, WorkingBuffer, CursorPosition, StringMap)
			end
		end
	end
	return WorkingBuffer, CursorPosition
end

UnpackDataFromBuffer = function(InstructionList : { Instruction }, WorkingBuffer : buffer, CursorPosition : number, StringList : { string }) : (any, number)
	local Data : { [string] : any } = {}

	for InstructionIndex : number, Item : Instruction in InstructionList do
		if Item.DataType == "UInt8" then
			Data[Item.Key] = buffer.readu8(WorkingBuffer, CursorPosition)
			CursorPosition += 1
		elseif Item.DataType == "UInt16" then
			Data[Item.Key] = buffer.readu16(WorkingBuffer, CursorPosition)
			CursorPosition += 2
		elseif Item.DataType == "UInt32" then
			Data[Item.Key] = buffer.readu32(WorkingBuffer, CursorPosition)
			CursorPosition += 4
		elseif Item.DataType == "Float64" then
			Data[Item.Key] = buffer.readf64(WorkingBuffer, CursorPosition)
			CursorPosition += 8
		elseif Item.DataType == "Boolean" then
			Data[Item.Key] = (buffer.readu8(WorkingBuffer, CursorPosition) == 1)
			CursorPosition += 1
		elseif Item.DataType == "String" then
			local StringIndex : number = buffer.readu32(WorkingBuffer, CursorPosition)
			CursorPosition += 4
			Data[Item.Key] = StringList[StringIndex] or ""
		elseif Item.DataType == "Dictionary" and Item.Children then
			local ChildData : any
			local NewCursorPosition : number
			ChildData, NewCursorPosition = UnpackDataFromBuffer(Item.Children, WorkingBuffer, CursorPosition, StringList)
			Data[Item.Key] = ChildData
			CursorPosition = NewCursorPosition
		elseif Item.DataType == "List" and Item.Children then
			local Count : number = buffer.readu32(WorkingBuffer, CursorPosition)
			CursorPosition += 4
			local ListTable : { any } = {}

			for i : number = 1, Count do
				local Container : any
				Container, CursorPosition = UnpackDataFromBuffer(Item.Children, WorkingBuffer, CursorPosition, StringList)
				table.insert(ListTable, Container["_Item"])
			end
			Data[Item.Key] = ListTable
		end
	end
	return Data, CursorPosition
end

function TitanBinary.Serialize(StoreName : string, Data : any) : string
	local InstructionList : { Instruction } = InstructionCache[StoreName]
	if not InstructionList then
		error("SchemaNotCompiled")
	end

	local StringMap : { [string] : number } = {}
	local StringList : { string } = {}
	CollectInternedStrings(Data, InstructionList, StringMap, StringList)

	local WorkingBuffer : buffer = AcquireBuffer()
	local CursorPosition : number = 0

	WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 1)
	buffer.writeu8(WorkingBuffer, CursorPosition, BinaryVersion)
	CursorPosition += 1

	local StringCount : number = #StringList
	WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 4)
	buffer.writeu32(WorkingBuffer, CursorPosition, StringCount)
	CursorPosition += 4

	for StringIndex : number, StringValue : string in StringList do
		local StringLength : number = #StringValue
		WorkingBuffer = EnsureBufferCapacity(WorkingBuffer, CursorPosition, 4 + StringLength)
		buffer.writeu32(WorkingBuffer, CursorPosition, StringLength)
		CursorPosition += 4
		buffer.writestring(WorkingBuffer, CursorPosition, StringValue)
		CursorPosition += StringLength
	end

	WorkingBuffer, CursorPosition = PackDataToBuffer(Data, InstructionList, WorkingBuffer, CursorPosition, StringMap)

	local TrimmedBuffer : buffer = buffer.create(CursorPosition)
	buffer.copy(TrimmedBuffer, 0, WorkingBuffer, 0, CursorPosition)
	ReleaseBuffer(WorkingBuffer)

	local CompressedBuffer : buffer = EncodingService:CompressBuffer(TrimmedBuffer, Enum.CompressionAlgorithm.Zstd)
	local Base64Buffer : buffer = EncodingService:Base64Encode(CompressedBuffer)

	return buffer.tostring(Base64Buffer)
end

function TitanBinary.Deserialize(StoreName : string, Base64String : string) : (any, boolean)
	local InstructionList : { Instruction } = InstructionCache[StoreName]
	if not InstructionList then
		error("SchemaNotCompiled")
	end

	if Base64String == "" then
		return nil, false
	end

	local IsSuccess : boolean, Result : any = pcall(function()
		local Base64Buffer : buffer = buffer.fromstring(Base64String)
		local CompressedBuffer : buffer = EncodingService:Base64Decode(Base64Buffer)
		local RawBuffer : buffer = EncodingService:DecompressBuffer(CompressedBuffer, Enum.CompressionAlgorithm.Zstd)

		local CursorPosition : number = 0

		local Version : number = buffer.readu8(RawBuffer, CursorPosition)
		CursorPosition += 1

		if Version ~= BinaryVersion then
			error("Binary Version Mismatch")
		end

		local StringList : { string } = {}
		local StringCount : number = buffer.readu32(RawBuffer, CursorPosition)
		CursorPosition += 4

		for StringIndex : number = 1, StringCount do
			local StringLength : number = buffer.readu32(RawBuffer, CursorPosition)
			CursorPosition += 4
			local StringValue : string = buffer.readstring(RawBuffer, CursorPosition, StringLength)
			CursorPosition += StringLength
			table.insert(StringList, StringValue)
		end

		local Data : any
		Data, _ = UnpackDataFromBuffer(InstructionList, RawBuffer, CursorPosition, StringList)
		return Data
	end)

	if IsSuccess then
		return Result, true
	else
		return nil, false
	end
end

return TitanBinary
