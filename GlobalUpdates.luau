--!strict
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local TitanRegistry = require(script.Parent.Registry)

local TitanGlobalUpdates = {}

local GlobalUpdateStoreName : string = "TitanGlobalUpdates_V1"
local GlobalUpdateStore = DataStoreService:GetDataStore(GlobalUpdateStoreName)
local MaxQueueSize : number = 50

export type GlobalUpdatePayload = {
	UpdateId : string,
	Type : string,
	Data : any,
	Created : number,
	SenderId : number?
}

function TitanGlobalUpdates.AddUpdate(TargetUserId : number, UpdateType : string, UpdateData : any, SenderId : number?) : boolean
	local UserKey : string = TitanRegistry.GetUserKey(TargetUserId)
	local UpdateId : string = HttpService:GenerateGUID(false)

	local Payload : GlobalUpdatePayload = {
		UpdateId = UpdateId,
		Type = UpdateType,
		Data = UpdateData,
		Created = os.time(),
		SenderId = SenderId
	}

	local Success : boolean, Result : any = pcall(function() 
		return GlobalUpdateStore:UpdateAsync(UserKey, function(CurrentQueue : any) : any
			local Queue : { GlobalUpdatePayload } = CurrentQueue or {}

			if #Queue > MaxQueueSize then
				return nil
			end

			table.insert(Queue, Payload)
			return Queue 
		end)
	end)

	return Success
end

function TitanGlobalUpdates.GetPendingUpdates(TargetUserId : number) : { GlobalUpdatePayload }
	local UserKey : string = TitanRegistry.GetUserKey(TargetUserId)
	local Success : boolean, Result : any = pcall(function()
		return GlobalUpdateStore:GetAsync(UserKey)
	end)

	if Success and Result then
		return Result
	end
	return {}
end

function TitanGlobalUpdates.ClearUpdates(TargetUserId : number, ProcessedIds : { string })
	if #ProcessedIds == 0 then
		return
	end

	local UserKey : string = TitanRegistry.GetUserKey(TargetUserId)

	pcall(function()
		GlobalUpdateStore:UpdateAsync(UserKey, function(CurrentQueue : any) : any
			local Queue : { GlobalUpdatePayload } = CurrentQueue or {}
			local NewQueue : { GlobalUpdatePayload } = {}
			local IdMap : { [string] : boolean } = {}

			for _, Id : string in ProcessedIds do
				IdMap[Id] = true
			end

			for _, Update : GlobalUpdatePayload in Queue do
				if not IdMap[Update.UpdateId] then
					table.insert(NewQueue, Update)
				end
			end

			return NewQueue
		end)
	end)
end

return TitanGlobalUpdates