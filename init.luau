--!strict
local TitanCore = require(script.Core)
local TitanSchema = require(script.Schema)
local TitanMailbox = require(script.Mailbox)

local Titan = {}

export type SchemaDefinition = TitanSchema.SchemaDefinition
export type TitanEngine<T> = TitanCore.TitanEngine<T>
export type GiftPayload = TitanMailbox.GiftPayload

type Configuration = {
	StoreName : string,
	Schema : SchemaDefinition,
	MemoryExpirationSeconds : number,
	WriteCooldownSeconds : number,
	AutoSaveIntervalSeconds : number,
	StaleSessionTimeoutSeconds : number?,
	SchemaVersion : number?,
	Migrations : { [number] : (any) -> any }?
}

function Titan.New(Configuration : Configuration)
	return TitanCore.New({
		StoreName = Configuration.StoreName,
		Schema = Configuration.Schema,
		MemoryExpirationSeconds = Configuration.MemoryExpirationSeconds,
		WriteCooldownSeconds = Configuration.WriteCooldownSeconds,
		AutoSaveIntervalSeconds = Configuration.AutoSaveIntervalSeconds,
		StaleSessionTimeoutSeconds = Configuration.StaleSessionTimeoutSeconds,
		SchemaVersion = Configuration.SchemaVersion or 1,
		Migrations = Configuration.Migrations or {}
	})
end

Titan.Dictionary = TitanSchema.Dictionary
Titan.List = TitanSchema.List
Titan.String = TitanSchema.String
Titan.Boolean = TitanSchema.Boolean
Titan.Number = TitanSchema.Number
Titan.UInt8 = TitanSchema.UInt8
Titan.UInt16 = TitanSchema.UInt16
Titan.UInt32 = TitanSchema.UInt32
Titan.Integer = TitanSchema.Integer

Titan.Mailbox = TitanMailbox

return Titan