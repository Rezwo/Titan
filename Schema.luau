--!strict
export type ValidationResult = {
	IsValid : boolean,
	CleanData : any?
}

export type SchemaDefinition = {
	Validate : (any, any) -> ValidationResult,
	GenerateTemplate : (any) -> any,
	SetDefault : (any, any) -> SchemaDefinition,
	SetMinimum : (any, number) -> SchemaDefinition,
	SetMaximum : (any, number) -> SchemaDefinition,

	_Type : string,
	_Default : any,
	_Minimum : number?,
	_Maximum : number?,
	_Structure : { [string] : SchemaDefinition }?,
	_ContentType : SchemaDefinition?
}

local TitanSchema = {}

local function CreateDefinition(TypeLabel : string, ValidatorFunction : (any) -> (boolean, any)) : SchemaDefinition
	local Definition = {
		_Type = TypeLabel,
		_Default = nil,
		_Minimum = nil,
		_Maximum = nil,
		_Structure = nil,
		_ContentType = nil,
		Validate = nil :: any,
		GenerateTemplate = nil :: any,
		SetDefault = nil :: any,
		SetMinimum = nil :: any,
		SetMaximum = nil :: any
	} :: SchemaDefinition

	function Definition.Validate(Self : any, Input : any) : ValidationResult
		if Input == nil then
			return {
				IsValid = Self._Default ~= nil,
				CleanData = Self._Default
			}
		end

		local IsSuccess : boolean, CleanValue : any = ValidatorFunction(Input)
		if not IsSuccess then
			return {
				IsValid = Self._Default ~= nil,
				CleanData = Self._Default
			}
		end

		if type(CleanValue) == "number" then
			if Self._Minimum and CleanValue < Self._Minimum then
				CleanValue = Self._Minimum
			end
			if Self._Maximum and CleanValue > Self._Maximum then
				CleanValue = Self._Maximum
			end
		end

		return {
			IsValid = true,
			CleanData = CleanValue
		}
	end

	function Definition.GenerateTemplate(Self : any)
		if Self._Structure then
			local TemplateTable : { [string] : any } = {}
			for Key : string, SubDefinition : SchemaDefinition in Self._Structure do
				TemplateTable[Key] = (SubDefinition :: any):GenerateTemplate()
			end
			return TemplateTable
		elseif Self._Default ~= nil then
			return Self._Default
		end

		if Self._Type == "String" then
			return ""
		end
		if Self._Type == "Float64" or Self._Type == "UInt32" or Self._Type == "UInt16" or Self._Type == "UInt8" then
			return 0
		end
		if Self._Type == "Boolean" then
			return false
		end
		if Self._Type == "List" then
			return {}
		end

		return nil
	end

	function Definition.SetDefault(Self : any, Value : any)
		Self._Default = Value
		return Self
	end

	function Definition.SetMinimum(Self : any, Value : number)
		Self._Minimum = Value
		return Self
	end

	function Definition.SetMaximum(Self : any, Value : number)
		Self._Maximum = Value
		return Self
	end

	return Definition
end

function TitanSchema.String()
	return CreateDefinition("String", function(Value : any) : (boolean, any)
		return type(Value) == "string", Value
	end)
end

function TitanSchema.Boolean()
	return CreateDefinition("Boolean", function(Value : any) : (boolean, any)
		return type(Value) == "boolean", Value
	end)
end

function TitanSchema.Number()
	return CreateDefinition("Float64", function(Value : any) : (boolean, any)
		return type(Value) == "number", Value
	end)
end

function TitanSchema.UInt8()
	return CreateDefinition("UInt8", function(Value : any) : (boolean, any)
		if type(Value) ~= "number" then
			return false, 0
		end
		return true, math.clamp(math.floor(Value), 0, 255)
	end)
end

function TitanSchema.UInt16()
	return CreateDefinition("UInt16", function(Value : any) : (boolean, any)
		if type(Value) ~= "number" then
			return false, 0
		end
		return true, math.clamp(math.floor(Value), 0, 65535)
	end)
end

function TitanSchema.UInt32()
	return CreateDefinition("UInt32", function(Value : any) : (boolean, any)
		if type(Value) ~= "number" then
			return false, 0
		end
		local Floored : number = math.floor(Value)
		return Floored >= 0, math.max(0, Floored)
	end)
end

function TitanSchema.Integer()
	return TitanSchema.UInt32()
end

function TitanSchema.List(ContentType : SchemaDefinition)
	local Definition = CreateDefinition("List", function(Value : any) : (boolean, any)
		if type(Value) ~= "table" then
			return false, nil
		end
		local CleanList : { any } = {}
		local ContentTypeAny : any = ContentType

		for ItemIndex : number, Item : any in Value :: { any } do
			local Result : ValidationResult = ContentTypeAny:Validate(Item)
			if Result.IsValid then
				table.insert(CleanList, Result.CleanData)
			end
		end
		return true, CleanList
	end)
	Definition._ContentType = ContentType
	return Definition
end

function TitanSchema.Dictionary(Structure : { [string] : SchemaDefinition })
	local Definition = CreateDefinition("Dictionary", function(Value : any) : (boolean, any)
		if type(Value) ~= "table" then
			return false, nil
		end
		local ValueTable = Value :: { [string] : any }
		local CleanDictionary : { [string] : any } = {}

		for Key : string, SubDefinition : SchemaDefinition in Structure do
			local SubDefinitionAny : any = SubDefinition
			local Result : ValidationResult = SubDefinitionAny:Validate(ValueTable[Key])
			if Result.IsValid then
				CleanDictionary[Key] = Result.CleanData
			else
				return false, nil
			end
		end
		return true, CleanDictionary
	end)
	Definition._Structure = Structure
	return Definition
end

return TitanSchema