--!strict
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local TitanMailbox = {}

local MailboxDataStoreName : string = "TitanMailbox_Production"
local MaxInboxSize : number = 50
local CooldownSeconds : number = 1
local CooldownCleanupInterval : number = 60
local MaxItemNameLength : number = 50
local MaxQuantity : number = 999999

local MailboxDataStore = DataStoreService:GetDataStore(MailboxDataStoreName)
local LastSendTime : { [number] : number } = {}

task.spawn(function()
	while true do
		task.wait(CooldownCleanupInterval)
		local Now : number = os.time()
		for UserId : number, Timestamp : number in LastSendTime do
			if Now - Timestamp > CooldownCleanupInterval then
				LastSendTime[UserId] = nil
			end
		end
	end
end)

export type GiftPayload = {
	TransactionId : string,
	FromUserId : number,
	ItemName : string,
	Quantity : number
}

local function ValidateGiftInputs(FromUserId : number, ToUserId : number, ItemName : string, Quantity : number) : (boolean, string?)
	if type(FromUserId) ~= "number" or FromUserId <= 0 then
		return false, "Invalid FromUserId"
	end
	if type(ToUserId) ~= "number" or ToUserId <= 0 then
		return false, "Invalid ToUserId"
	end
	if FromUserId == ToUserId then
		return false, "Cannot send gift to self"
	end

	if type(ItemName) ~= "string" or #ItemName == 0 or #ItemName > MaxItemNameLength then
		return false, "Invalid ItemName"
	end

	if type(Quantity) ~= "number" or Quantity <= 0 or Quantity > MaxQuantity or Quantity % 1 ~= 0 then
		return false, "Invalid Quantity"
	end

	return true, nil
end

function TitanMailbox.SendGift(FromUserId : number, ToUserId : number, ItemName : string, Quantity : number) : (boolean, string?)
	local IsValid : boolean, ValidationError : string? = ValidateGiftInputs(FromUserId, ToUserId, ItemName, Quantity)
	if not IsValid then
		return false, ValidationError
	end

	local Now : number = os.time()
	if LastSendTime[FromUserId] and (Now - LastSendTime[FromUserId]) < CooldownSeconds then
		return false, "Cooldown active"
	end
	LastSendTime[FromUserId] = Now

	local Payload : GiftPayload = {
		TransactionId = HttpService:GenerateGUID(false),
		FromUserId = FromUserId,
		ItemName = ItemName,
		Quantity = Quantity
	}

	local IsSuccess : boolean, Result : any = pcall(function()
		return MailboxDataStore:UpdateAsync(tostring(ToUserId), function(CurrentBox : any)
			local Inbox : { GiftPayload } = CurrentBox or {}

			if #Inbox >= MaxInboxSize then
				error("INBOX_FULL")
			end

			table.insert(Inbox, Payload)
			return Inbox
		end)
	end)

	if not IsSuccess then
		local ErrorMsg : string = tostring(Result)
		if string.find(ErrorMsg, "INBOX_FULL") then
			return false, "Recipient inbox is full"
		end
		return false, "DataStore System Error"
	end

	return true, nil
end

function TitanMailbox.ClaimInbox(UserId : number, AcknowledgedIds : { [string] : boolean }?) : { GiftPayload }
	local Result : { GiftPayload } = {}
	local IdsToClear : { [string] : boolean } = AcknowledgedIds or {}

	pcall(function()
		MailboxDataStore:UpdateAsync(tostring(UserId), function(CurrentBox : any)
			local Inbox : { GiftPayload } = CurrentBox or {}
			local KeptInbox : { GiftPayload } = {}
			local UnseenItems : { GiftPayload } = {}

			for GiftIndex : number, Gift : GiftPayload in Inbox do
				if not IdsToClear[Gift.TransactionId] then
					table.insert(KeptInbox, Gift)
					table.insert(UnseenItems, Gift)
				end
			end

			Result = UnseenItems
			return #KeptInbox == 0 and {} or KeptInbox
		end)
	end)

	return Result
end

return TitanMailbox