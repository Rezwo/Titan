--!strict
local TitanRegistry = {}
local UserKeyCache : { [number] : string } = {}

function TitanRegistry.GetUserKey(UserId : number) : string
	if UserKeyCache[UserId] then
		return UserKeyCache[UserId]
	end
	local NewKey : string = "User_" .. tostring(UserId)
	UserKeyCache[UserId] = NewKey
	return NewKey
end

function TitanRegistry.ClearUserKey(UserId : number)
	UserKeyCache[UserId] = nil
end

return TitanRegistry