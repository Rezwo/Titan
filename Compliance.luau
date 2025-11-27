--!strict
local DataStoreService = game:GetService("DataStoreService")

local TitanCompliance = {}

local RegisteredStores : { string } = {
	"TitanData_Production_V1",
	"TitanMailbox_Production"
}

function TitanCompliance.WipeUser(UserId : number)
	local UserKey : string = "User_" .. tostring(UserId)
	local MailboxKey : string = tostring(UserId)

	for _, StoreName : string in ipairs(RegisteredStores) do
		local DataStore = DataStoreService:GetDataStore(StoreName)
		pcall(function()
			DataStore:RemoveAsync(UserKey)
		end)
		pcall(function()
			DataStore:RemoveAsync(MailboxKey)
		end)
	end
	print("TitanCompliance: Wiped Data for User", UserId)
end

return TitanCompliance