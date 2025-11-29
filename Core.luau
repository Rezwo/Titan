--!strict
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

local TitanRegistry = require(script.Parent.Registry)
local TitanBinary = require(script.Parent.Binary)
local TitanSchema = require(script.Parent.Schema)

local StaleSessionCheckInterval : number = 600
local HealthCheckInterval : number = 60
local MaxMemoryStoreWrites : number = 10
local LockTimeoutBase : number = 30
local AutoSaveSafeLimit : number = 600
local CircuitBreakerThreshold : number = 5
local CircuitBreakerResetTime : number = 60
local MaxDataStoreSize : number = 3800000

export type MigrationFunction = (any) -> any

export type SystemConfiguration = {
	StoreName : string,
	Schema : TitanSchema.SchemaDefinition,
	MemoryExpirationSeconds : number,
	WriteCooldownSeconds : number,
	AutoSaveIntervalSeconds : number,
	StaleSessionTimeoutSeconds : number?,
	SchemaVersion : number?,
	Migrations : { [number] : MigrationFunction }?
}

export type RegistryEntry<T> = {
	Data : T,
	SessionIdentifier : string,
	LastWriteTime : number,
	LastAccessTime : number,
	Status : "Ready" | "Released" | "Locked", 
	IsDirty : boolean,
	ConsecutiveFailures : number,
	IsSharded : boolean
}

export type CachedDataResult<T> = {
	Data : T,
	SessionId : string?,
	Timestamp : number,
	IsLocalSession : boolean
}

export type TitanEngine<T> = {
	Configuration : SystemConfiguration,
	PersistentStore : DataStore,
	MemoryCacheStore : MemoryStoreSortedMap,
	DataRegistry : { [string] : RegistryEntry<T> },
	UpdateQueue : { [string] : boolean? },
	LoadingUsers : { [string] : number },
	CircuitBreaker : { IsOpen : boolean, LastFailTime : number, Failures : number },
	Metrics : {
		TotalSaves : number,
		FailedSaves : number,
		TotalLoads : number,
		FailedLoads : number,
		LastHealthyTime : number
	},
	MemoryWriteSemaphore : number,
	UpdateHook : ((number, T) -> ())?,

	MarkDirty : (TitanEngine<T>, number) -> (),
	UpdateData : (TitanEngine<T>, number, (T) -> boolean) -> boolean,
	ProcessUpdateQueue : (TitanEngine<T>) -> (),
	ExpectData : (TitanEngine<T>, number) -> T?,
	GetCachedData : (TitanEngine<T>, number) -> CachedDataResult<T>?,
	GetCachedDataBatch : (TitanEngine<T>, { number }) -> { [number] : CachedDataResult<T> },
	PerformAutoSave : (TitanEngine<T>) -> (),
	ReleaseData : (TitanEngine<T>, number) -> (),
	ForceReleaseLock : (TitanEngine<T>, number) -> (),
	ApplyMigrations : (TitanEngine<T>, any) -> (boolean, any, boolean),
	CleanupStaleSessions : (TitanEngine<T>) -> (),
	GetActiveSessionCount : (TitanEngine<T>) -> number,
	GetMetrics : (TitanEngine<T>) -> any,
	SetUpdateHook : (TitanEngine<T>, (number, T) -> ()) -> (),
	SaveShardedData : (TitanEngine<T>, string, string) -> (boolean, any),
	LoadShardedData : (TitanEngine<T>, string, any) -> string?,
	RunTransaction : (TitanEngine<T>, { number }, ({ [number] : any }) -> boolean) -> boolean
}

local function DeepCopy(Table : any) : any
	if type(Table) ~= "table" then
		return Table
	end
	local Clone : any = {}
	for Key : any, Value : any in Table do
		if type(Value) == "table" then
			Clone[Key] = DeepCopy(Value)
		else
			Clone[Key] = Value
		end
	end
	return Clone
end

local function CheckCircuitBreaker(Engine : TitanEngine<any>) : boolean
	if Engine.CircuitBreaker.IsOpen then
		local TimeSinceFailure : number = os.time() - Engine.CircuitBreaker.LastFailTime
		if TimeSinceFailure > CircuitBreakerResetTime then
			Engine.CircuitBreaker.IsOpen = false
			Engine.CircuitBreaker.Failures = 0
			return true
		else
			return false
		end
	end
	return true
end

local function ExecuteRetry(Attempts : number, CallbackFunction : () -> any, Engine : TitanEngine<any>?) : (boolean, any)
	if Engine and not CheckCircuitBreaker(Engine) then
		return false, "Circuit Breaker Open"
	end

	for AttemptIndex : number = 1, Attempts do
		local IsSuccess : boolean, Result : any = pcall(CallbackFunction)
		if IsSuccess then
			if Engine then
				Engine.CircuitBreaker.Failures = 0
				Engine.CircuitBreaker.IsOpen = false
				Engine.Metrics.LastHealthyTime = os.time()
			end
			return true, Result
		end

		if AttemptIndex < Attempts then
			task.wait(1 * math.pow(2, AttemptIndex - 1))
		end
	end

	if Engine then
		Engine.CircuitBreaker.Failures += 1
		Engine.CircuitBreaker.LastFailTime = os.time()

		if Engine.CircuitBreaker.Failures >= CircuitBreakerThreshold then
			Engine.CircuitBreaker.IsOpen = true
		end
	end

	return false, nil
end

local TitanCore = {}
TitanCore.__index = TitanCore

function TitanCore.New<T>(Configuration : SystemConfiguration) : TitanEngine<T>
	Configuration.SchemaVersion = Configuration.SchemaVersion or 1
	Configuration.Migrations = Configuration.Migrations or {}
	Configuration.StaleSessionTimeoutSeconds = Configuration.StaleSessionTimeoutSeconds or 3600

	if Configuration.Schema._Structure then
		TitanBinary.CompileSchema(Configuration.StoreName, Configuration.Schema._Structure)
	else
		TitanBinary.CompileSchema(Configuration.StoreName, Configuration.Schema)
	end

	TitanBinary.CompileSchema("TitanInternal_MemoryPacket", {
		D = TitanSchema.String(),
		S = TitanSchema.String(),
		T = TitanSchema.UInt32()
	})

	local Self = setmetatable({
		Configuration = Configuration,
		PersistentStore = DataStoreService:GetDataStore(Configuration.StoreName),
		MemoryCacheStore = MemoryStoreService:GetSortedMap(Configuration.StoreName .. "_TitanNative"),
		DataRegistry = {} :: { [string] : RegistryEntry<T> },
		UpdateQueue = {} :: { [string] : boolean? },
		LoadingUsers = {} :: { [string] : number },
		CircuitBreaker = { IsOpen = false, LastFailTime = 0, Failures = 0 },
		Metrics = {
			TotalSaves = 0,
			FailedSaves = 0,
			TotalLoads = 0,
			FailedLoads = 0,
			LastHealthyTime = os.time()
		},
		MemoryWriteSemaphore = 0,
		UpdateHook = nil
	}, TitanCore)

	local Instance : TitanEngine<T> = (Self :: any) :: TitanEngine<T>

	task.spawn(function()
		while true do
			task.wait(1)
			Instance:ProcessUpdateQueue()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Configuration.AutoSaveIntervalSeconds)
			Instance:PerformAutoSave()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(StaleSessionCheckInterval)
			Instance:CleanupStaleSessions()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(HealthCheckInterval)
			if Instance.CircuitBreaker.IsOpen then
				local Success : boolean = ExecuteRetry(1, function()
					return Instance.PersistentStore:GetAsync("_TITAN_HEALTH_CHECK_")
				end, Instance)
			end
		end
	end)

	return Instance
end

function TitanCore.SetUpdateHook(Self : TitanEngine<any>, Callback : (number, any) -> ())
	Self.UpdateHook = Callback
end

function TitanCore.SaveShardedData(Self : TitanEngine<any>, UserKey : string, Payload : string) : (boolean, any)
	local PayloadSize : number = #Payload

	if PayloadSize <= MaxDataStoreSize then
		return true, Payload
	end

	local ChunkCount : number = math.ceil(PayloadSize / MaxDataStoreSize)
	local BatchId : string = HttpService:GenerateGUID(false)

	for ChunkIndex : number = 1, ChunkCount do
		local StartIndex : number = ((ChunkIndex - 1) * MaxDataStoreSize) + 1
		local EndIndex : number = math.min(StartIndex + MaxDataStoreSize - 1, PayloadSize)
		local ChunkData : string = string.sub(Payload, StartIndex, EndIndex)

		local ChunkKey : string = UserKey .. "_C_" .. BatchId .. "_" .. ChunkIndex

		local Success : boolean = ExecuteRetry(3, function()
			Self.PersistentStore:SetAsync(ChunkKey, ChunkData)
		end, Self)

		if not Success then
			return false, "Chunk Save Failed"
		end
	end

	return true, {
		_IsSharded = true,
		ChunkCount = ChunkCount,
		BatchId = BatchId,
		TotalSize = PayloadSize
	}
end

function TitanCore.LoadShardedData(Self : TitanEngine<any>, UserKey : string, Data : any) : string?
	if type(Data) == "table" and Data._IsSharded then
		local Chunks : { string } = {}
		local ChunkCount : number = Data.ChunkCount
		local BatchId : string = Data.BatchId or "" 

		for ChunkIndex : number = 1, ChunkCount do
			local ChunkKey : string = if BatchId ~= "" then UserKey .. "_C_" .. BatchId .. "_" .. ChunkIndex else UserKey .. "_Chunk_" .. ChunkIndex

			local Success : boolean, ChunkData : any = ExecuteRetry(3, function()
				return Self.PersistentStore:GetAsync(ChunkKey)
			end, Self)

			if not Success or not ChunkData then
				return nil
			end
			table.insert(Chunks, ChunkData)
		end

		return table.concat(Chunks)
	end

	return Data
end

function TitanCore.CleanupStaleSessions(Self : TitanEngine<any>)
	local StaleThreshold : number = Self.Configuration.StaleSessionTimeoutSeconds or 3600
	local CurrentTime : number = os.time()

	for UserKey : string, Entry : RegistryEntry<any> in Self.DataRegistry do
		if Self.LoadingUsers[UserKey] and (CurrentTime - Self.LoadingUsers[UserKey] > LockTimeoutBase) then
			Self.LoadingUsers[UserKey] = nil
		end

		if CurrentTime - Entry.LastAccessTime > StaleThreshold then
			local UserId : number? = tonumber(string.match(UserKey, "User_(%d+)"))
			if UserId then
				Self:ReleaseData(UserId)
			end
		end
	end
end

function TitanCore.ApplyMigrations(Self : TitanEngine<any>, Data : any) : (boolean, any, boolean)
	if not Data then
		return true, nil, false
	end

	local CurrentVersion : number = Data._SchemaVersion or 0
	local TargetVersion : number = Self.Configuration.SchemaVersion or 1
	local DidMigrate : boolean = false

	if CurrentVersion >= TargetVersion then
		return true, Data, false
	end

	local Success : boolean, Result : any = pcall(function()
		local TempData : any = Data
		local Migrations : { [number] : MigrationFunction }? = Self.Configuration.Migrations

		for VersionIndex : number = CurrentVersion + 1, TargetVersion do
			local MigrationStep : MigrationFunction? = if Migrations then Migrations[VersionIndex] else nil
			if MigrationStep then
				TempData = MigrationStep(TempData)
				DidMigrate = true
			end
		end
		TempData._SchemaVersion = TargetVersion
		return TempData
	end)

	if Success then
		return true, Result, DidMigrate
	else
		return false, Data, false
	end
end

function TitanCore.MarkDirty(Self : TitanEngine<any>, UserId : number)
	local UserKey : string = TitanRegistry.GetUserKey(UserId)
	local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]

	if Entry and Entry.Status == "Ready" then
		Entry.IsDirty = true
		Entry.LastAccessTime = os.time()
		Self.UpdateQueue[UserKey] = true
	end
end

function TitanCore.UpdateData(Self : TitanEngine<any>, UserId : number, Callback : (any) -> boolean) : boolean
	local UserKey : string = TitanRegistry.GetUserKey(UserId)
	local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]

	if not Entry or Entry.Status ~= "Ready" then
		return false
	end

	local Success : boolean, ShouldSave : any = pcall(Callback, Entry.Data)
	if not Success then
		return false
	end

	Entry.LastAccessTime = os.time()

	if ShouldSave then
		local ValidationResult : any = Self.Configuration.Schema:Validate(Entry.Data)
		if not ValidationResult.IsValid then
			return false
		end
		Self:MarkDirty(UserId)

		if Self.UpdateHook then
			Self.UpdateHook(UserId, Entry.Data)
		end

		return true
	end

	return false
end

function TitanCore.ProcessUpdateQueue(Self : TitanEngine<any>)
	local CurrentClock : number = os.clock()
	local CurrentTime : number = os.time()
	local CooldownSeconds : number = Self.Configuration.WriteCooldownSeconds

	for UserKey : string, _ : boolean? in Self.UpdateQueue do
		local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]

		if Entry and Entry.Status == "Ready" then
			if (CurrentClock - Entry.LastWriteTime) >= CooldownSeconds then

				if Self.MemoryWriteSemaphore >= MaxMemoryStoreWrites then
					continue
				end

				Self.UpdateQueue[UserKey] = nil
				Entry.LastWriteTime = CurrentClock

				local PayloadString : string = TitanBinary.Serialize(Self.Configuration.StoreName, Entry.Data)
				local Packet : any = {
					D = PayloadString,
					S = Entry.SessionIdentifier,
					T = CurrentTime
				}
				local PacketBinary : string = TitanBinary.Serialize("TitanInternal_MemoryPacket", Packet)

				Self.MemoryWriteSemaphore += 1
				task.spawn(function()
					local WriteSuccess : boolean = ExecuteRetry(3, function()
						Self.MemoryCacheStore:SetAsync(
							UserKey,
							PacketBinary,
							Self.Configuration.MemoryExpirationSeconds
						)
					end, Self)

					Self.MemoryWriteSemaphore -= 1
				end)
			end
		end
	end
end

function TitanCore.GetCachedData(Self : TitanEngine<any>, UserId : number) : CachedDataResult<any>?
	local UserKey : string = TitanRegistry.GetUserKey(UserId)

	local LocalEntry : RegistryEntry<any>? = Self.DataRegistry[UserKey]
	if LocalEntry and LocalEntry.Status == "Ready" then
		return {
			Data = LocalEntry.Data,
			SessionId = LocalEntry.SessionIdentifier,
			Timestamp = os.time(),
			IsLocalSession = true
		}
	end

	local Success : boolean, CachedBinary : any = pcall(function()
		return Self.MemoryCacheStore:GetAsync(UserKey)
	end)

	if Success and CachedBinary then
		local Packet : any, PacketSuccess : boolean = TitanBinary.Deserialize("TitanInternal_MemoryPacket", CachedBinary)
		if PacketSuccess and Packet and Packet.D then
			local UserData : any, DataSuccess : boolean = TitanBinary.Deserialize(Self.Configuration.StoreName, Packet.D :: string)
			if DataSuccess then
				return {
					Data = UserData,
					SessionId = Packet.S,
					Timestamp = Packet.T,
					IsLocalSession = false
				}
			end
		end
	end

	return nil
end

function TitanCore.GetCachedDataBatch(Self : TitanEngine<any>, UserIds : { number }) : { [number] : CachedDataResult<any> }
	local Results : { [number] : CachedDataResult<any> } = {}
	local PendingMemoryLookups : { number } = {}

	for UserIndex : number, UserId : number in UserIds do
		local LocalResult : CachedDataResult<any>? = Self:GetCachedData(UserId)
		if LocalResult and LocalResult.IsLocalSession then
			Results[UserId] = LocalResult
		else
			table.insert(PendingMemoryLookups, UserId)
		end
	end

	local ChunkSize : number = 50

	local function ProcessChunk(Chunk : { number })
		local ThreadCount : number = 0
		local ChunkComplete : boolean = false
		local MainThread : thread = coroutine.running()
		local CancelToken : { Cancelled : boolean } = { Cancelled = false }

		for UserIndex : number, UserId : number in Chunk do
			ThreadCount += 1
			task.spawn(function()
				if not CancelToken.Cancelled then
					local Result : CachedDataResult<any>? = Self:GetCachedData(UserId)
					if Result and not CancelToken.Cancelled then
						Results[UserId] = Result
					end
				end

				ThreadCount -= 1
				if ThreadCount == 0 and not ChunkComplete then
					ChunkComplete = true
					task.spawn(MainThread)
				end
			end)
		end

		if ThreadCount > 0 then
			task.spawn(function()
				task.wait(5)
				if not ChunkComplete then
					ChunkComplete = true
					CancelToken.Cancelled = true
					task.spawn(MainThread)
				end
			end)

			coroutine.yield()
		end
	end

	if #PendingMemoryLookups > 0 then
		for ChunkStartIndex : number = 1, #PendingMemoryLookups, ChunkSize do
			local ChunkEnd : number = math.min(ChunkStartIndex + ChunkSize - 1, #PendingMemoryLookups)
			local Chunk : { number } = {}
			for LookupIndex : number = ChunkStartIndex, ChunkEnd do
				table.insert(Chunk, PendingMemoryLookups[LookupIndex])
			end

			ProcessChunk(Chunk)

			if ChunkStartIndex + ChunkSize <= #PendingMemoryLookups then
				task.wait(0.1)
			end
		end
	end

	return Results
end

function TitanCore.ExpectData(Self : TitanEngine<any>, UserId : number)
	local UserKey : string = TitanRegistry.GetUserKey(UserId)
	local CurrentTime : number = os.time()

	if Self.LoadingUsers[UserKey] then
		local LockAge : number = CurrentTime - Self.LoadingUsers[UserKey]
		if LockAge < LockTimeoutBase then
			return nil
		else
			Self.LoadingUsers[UserKey] = nil
		end
	end

	if Self.DataRegistry[UserKey] then
		Self.DataRegistry[UserKey].LastAccessTime = CurrentTime
		return Self.DataRegistry[UserKey].Data
	end

	Self.LoadingUsers[UserKey] = CurrentTime
	Self.Metrics.TotalLoads += 1

	local NewSessionIdentifier : string = HttpService:GenerateGUID(false)

	local IsSuccess : boolean, Result : any = ExecuteRetry(3, function()
		return Self.PersistentStore:UpdateAsync(UserKey, function(OldData : any)
			local RawData : any = nil

			if OldData and OldData.Data then
				return {
					Data = OldData.Data,
					Session = NewSessionIdentifier,
					Time = os.time()
				} :: any, { UserId }, { ["SessionID"] = NewSessionIdentifier, ["OwnerID"] = tostring(UserId) }
			end

			if not RawData then
				RawData = Self.Configuration.Schema:GenerateTemplate()
				RawData._SchemaVersion = Self.Configuration.SchemaVersion
			end

			return {
				Data = RawData,
				Session = NewSessionIdentifier,
				Time = os.time()
			} :: any, { UserId }, { ["SessionID"] = NewSessionIdentifier, ["OwnerID"] = tostring(UserId) }
		end)
	end, Self)

	Self.LoadingUsers[UserKey] = nil

	if not IsSuccess or not Result then
		Self.Metrics.FailedLoads += 1
		return nil
	end

	local LoadedData : any = Result.Data
	if type(LoadedData) == "table" and LoadedData._IsSharded then
		local ReconstructedString : string? = Self:LoadShardedData(UserKey, LoadedData)
		if ReconstructedString then
			local Decoded : any, Success : boolean = TitanBinary.Deserialize(Self.Configuration.StoreName, ReconstructedString)
			LoadedData = Success and Decoded or nil
		else
			return nil
		end
	elseif type(LoadedData) == "string" then
		local Decoded : any, Success : boolean = TitanBinary.Deserialize(Self.Configuration.StoreName, LoadedData)
		LoadedData = Success and Decoded or nil
	end

	local MigrationSuccess : boolean, MigratedData : any, DidMigrate : boolean = Self:ApplyMigrations(LoadedData)

	local ValidationResult : any = Self.Configuration.Schema:Validate(MigratedData)
	local FinalData : any = ValidationResult.IsValid and ValidationResult.CleanData or Self.Configuration.Schema:GenerateTemplate()
	FinalData._SchemaVersion = Self.Configuration.SchemaVersion

	if MigrationSuccess and DidMigrate then
		task.spawn(function()
			local Bin : string = TitanBinary.Serialize(Self.Configuration.StoreName, FinalData)
			local Success : boolean, Payload : any = Self:SaveShardedData(UserKey, Bin)

			if Success then
				ExecuteRetry(3, function()
					Self.PersistentStore:UpdateAsync(UserKey, function(Latest : any)
						if Latest and Latest.Session == NewSessionIdentifier then
							return {
								Data = Payload,
								Session = NewSessionIdentifier,
								Time = os.time()
							} :: any
						end
						return nil :: any
					end)
				end, Self)
			end
		end)
	end

	Self.DataRegistry[UserKey] = {
		Data = FinalData,
		SessionIdentifier = NewSessionIdentifier,
		LastWriteTime = os.clock(),
		LastAccessTime = CurrentTime,
		Status = "Ready",
		IsDirty = false,
		ConsecutiveFailures = 0,
		IsSharded = false
	}

	if Self.UpdateHook then
		Self.UpdateHook(UserId, FinalData)
	end

	return FinalData
end

function TitanCore.PerformAutoSave(Self : TitanEngine<any>)
	if Self.CircuitBreaker.IsOpen then
		return
	end

	local DirtyEntries : { { Key : string, Entry : RegistryEntry<any> } } = {}
	for UserKey : string, Entry : RegistryEntry<any> in Self.DataRegistry do
		if Entry.IsDirty and Entry.Status == "Ready" then
			table.insert(DirtyEntries, { Key = UserKey, Entry = Entry })
		end
	end

	if #DirtyEntries == 0 then
		return
	end

	local BatchSize : number = 10
	local SaveRequestsMade : number = 0
	local SaveWindowStart : number = os.time()

	for BatchStartIndex : number = 1, #DirtyEntries, BatchSize do
		local ElapsedSeconds : number = os.time() - SaveWindowStart

		if ElapsedSeconds >= 60 then
			SaveWindowStart = os.time()
			SaveRequestsMade = 0
		end

		if SaveRequestsMade > AutoSaveSafeLimit then
			task.wait(1)
		end

		local EndIndex : number = math.min(BatchStartIndex + BatchSize - 1, #DirtyEntries)
		local CurrentBatchCount : number = (EndIndex - BatchStartIndex) + 1
		SaveRequestsMade += CurrentBatchCount

		for EntryIndex : number = BatchStartIndex, EndIndex do
			local Item : { Key : string, Entry : RegistryEntry<any> } = DirtyEntries[EntryIndex]
			local UserKey : string = Item.Key
			local Entry : RegistryEntry<any> = Item.Entry

			task.spawn(function()
				Self.Metrics.TotalSaves += 1

				local BinaryPayload : string = TitanBinary.Serialize(Self.Configuration.StoreName, Entry.Data)

				local PrepareSuccess : boolean, Payload : any = Self:SaveShardedData(UserKey, BinaryPayload)

				if not PrepareSuccess then
					Self.Metrics.FailedSaves += 1
					Entry.ConsecutiveFailures += 1
					return
				end

				local SaveSuccess : boolean = ExecuteRetry(2, function()
					return Self.PersistentStore:UpdateAsync(UserKey, function(OldData : any)
						if OldData and OldData.Session ~= Entry.SessionIdentifier then
							return nil :: any
						end

						return {
							Data = Payload,
							Session = Entry.SessionIdentifier,
							Time = os.time()
						} :: any
					end)
				end, Self)

				if SaveSuccess then
					Entry.IsDirty = false
					Entry.ConsecutiveFailures = 0
				else
					Self.Metrics.FailedSaves += 1
					Entry.ConsecutiveFailures += 1
				end
			end)
		end

		local WaitTime : number = if #DirtyEntries > 100 then 0.05 else 0.1
		task.wait(WaitTime)
	end
end

function TitanCore.ReleaseData(Self : TitanEngine<any>, UserId : number)
	local UserKey : string = TitanRegistry.GetUserKey(UserId)
	local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]

	if not Entry then
		Self.UpdateQueue[UserKey] = nil
		Self.LoadingUsers[UserKey] = nil
		return
	end

	Entry.Status = "Released"

	local BinaryPayload : string = TitanBinary.Serialize(Self.Configuration.StoreName, Entry.Data)

	local PrepareSuccess : boolean, Payload : any = Self:SaveShardedData(UserKey, BinaryPayload)

	if PrepareSuccess then
		ExecuteRetry(3, function()
			Self.PersistentStore:UpdateAsync(UserKey, function(OldData : any)
				if OldData and OldData.Session ~= Entry.SessionIdentifier then
					return nil :: any
				end

				return {
					Data = Payload,
					Session = nil,
					Time = os.time()
				} :: any, { UserId }, { ["OwnerID"] = tostring(UserId) }
			end)
		end, Self)
	end

	Self.DataRegistry[UserKey] = nil
	Self.UpdateQueue[UserKey] = nil
	Self.LoadingUsers[UserKey] = nil
	TitanRegistry.ClearUserKey(UserId)
end

function TitanCore.ForceReleaseLock(Self : TitanEngine<any>, UserId : number)
	local UserKey : string = TitanRegistry.GetUserKey(UserId)
	if Self.DataRegistry[UserKey] then
		warn("Titan: Force releasing lock for user " .. UserId)
		Self.DataRegistry[UserKey] = nil
		Self.UpdateQueue[UserKey] = nil
		Self.LoadingUsers[UserKey] = nil
		TitanRegistry.ClearUserKey(UserId)
	end
end

function TitanCore.RunTransaction(Self : TitanEngine<any>, UserIds : { number }, Callback : ({ [number] : any }) -> boolean) : boolean
	local LockedKeys : { string } = {}
	local Context : { [number] : any } = {}

	local SortedIds : { number } = table.clone(UserIds)
	table.sort(SortedIds)

	for _, UserId : number in SortedIds do
		local UserKey : string = TitanRegistry.GetUserKey(UserId)
		local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]

		if not Entry or Entry.Status ~= "Ready" then
			for _, LockedKey : string in LockedKeys do
				local LockedEntry : RegistryEntry<any>? = Self.DataRegistry[LockedKey]
				if LockedEntry then
					LockedEntry.Status = "Ready"
				end
			end
			return false
		end

		Entry.Status = "Locked"
		table.insert(LockedKeys, UserKey)
	end

	for _, UserId : number in UserIds do
		local UserKey : string = TitanRegistry.GetUserKey(UserId)
		local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]
		if Entry then
			Context[UserId] = DeepCopy(Entry.Data)
		end
	end

	local Success : boolean, Result : any = pcall(Callback, Context)

	if Success and Result == true then
		local IsValid : boolean = true
		for _, UserId : number in UserIds do
			local NewData : any = Context[UserId]
			local ValidationResult : any = Self.Configuration.Schema:Validate(NewData)
			if not ValidationResult.IsValid then
				IsValid = false
				warn("Titan Transaction Error: Schema Validation Failed for User", UserId)
				break
			end
			Context[UserId] = ValidationResult.CleanData
		end

		if not IsValid then
			for _, UserKey : string in LockedKeys do
				local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]
				if Entry then
					Entry.Status = "Ready"
				end
			end
			return false
		end

		for _, UserId : number in UserIds do
			local UserKey : string = TitanRegistry.GetUserKey(UserId)
			local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]

			if Entry then
				Entry.Data = Context[UserId]
				Entry.Status = "Ready"
				Self:MarkDirty(UserId)
				if Self.UpdateHook then
					Self.UpdateHook(UserId, Entry.Data)
				end
			end
		end
		return true
	else
		for _, UserKey : string in LockedKeys do
			local Entry : RegistryEntry<any>? = Self.DataRegistry[UserKey]
			if Entry then
				Entry.Status = "Ready"
			end
		end
		return false
	end
end

function TitanCore.GetActiveSessionCount(Self : TitanEngine<any>) : number
	local Count : number = 0
	for _UserKey : string, Entry : RegistryEntry<any> in Self.DataRegistry do
		if Entry.Status == "Ready" then
			Count += 1
		end
	end
	return Count
end

function TitanCore.GetMetrics(Self : TitanEngine<any>) : any
	local ActiveSessions : number = Self:GetActiveSessionCount()
	local QueueSize : number = 0
	for _ in Self.UpdateQueue do
		QueueSize += 1
	end

	return {
		ActiveSessions = ActiveSessions,
		UpdateQueueSize = QueueSize,
		TotalSaves = Self.Metrics.TotalSaves,
		FailedSaves = Self.Metrics.FailedSaves,
		TotalLoads = Self.Metrics.TotalLoads,
		FailedLoads = Self.Metrics.FailedLoads,
		CircuitBreakerOpen = Self.CircuitBreaker.IsOpen,
		LastHealthy = Self.Metrics.LastHealthyTime
	}
end

return TitanCore