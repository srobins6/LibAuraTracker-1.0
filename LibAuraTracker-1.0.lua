--
-- Created by IntelliJ IDEA.
-- User: srobi
-- Date: 8/11/2016
-- Time: 3:47 PM
--

local _G = getfenv(0)
local LibStub = _G.LibStub
local MAJOR = "LibAuraTracker-1.0"
_G.assert(LibStub, MAJOR .. " requires LibStub")
local MINOR = 1 --Should be manually increased
local LibAuraTracker = LibStub:NewLibrary(MAJOR, MINOR)
if not LibAuraTracker then
    return
end --No upgrade needed
local Frame = CreateFrame("Frame")

local function round(num, idp)
    return tonumber(string.format("%." .. (idp or 0) .. "f", num))
end



local SpellIDs = {}
local Tracker = { Auras = {}, AuraFilters = {}, TrackedAuras = {}, LastTracked = {} }
setmetatable(Tracker, LibAuraTracker)
LibAuraTracker.__index = LibAuraTracker
local AuraInfo = {}

function AuraInfo:New(auraInfo)
    self.__index = self
    return setmetatable(auraInfo or {}, self)
end

local TrackedAurasMT = {
    __index = function(TrackedAuras, aura)
        if type(aura) == "number" then return TrackedAuras[string.lower(GetSpellInfo(aura) or "")] end
    end
}
local function Check(unit, aura, filter, sourceGUID, destGUID)
    if destGUID and UnitGUID(unit) ~= destGUID then
        return
    end
    local spellID = type(aura) == "number" and aura
    local spellName = GetSpellInfo(spellID) or aura
    filter = filter and string.upper(filter)
    local auraName, _, _, auraCount, _, auraDuration, auraExpirationTime, unitCaster, _, _, auraSpellID = UnitAura(unit, spellName, nil, filter)

    if (spellID and auraSpellID and spellID ~= auraSpellID) or (sourceGUID and unitCaster and sourceGUID ~= UnitGUID(unitCaster)) then
        for z = 1, 60 do
            auraName, _, _, auraCount, _, auraDuration, auraExpirationTime, unitCaster, _, _, auraSpellID = UnitAura(unit, z, filter)
            if not auraSpellID or auraSpellID == spellID and (not sourceGUID or unitCaster and sourceGUID == UnitGUID(unitCaster)) then
                break
            end
        end
    end

    if not auraName and (not filter or not filter:match("HARMFUL")) then
        auraName, _, _, auraCount, _, auraDuration, auraExpirationTime, unitCaster, _, _, auraSpellID = UnitDebuff(unit, spellName, nil, filter)
        if (spellID and auraSpellID and spellID ~= auraSpellID) or (sourceGUID and unitCaster and sourceGUID ~= UnitGUID(unitCaster)) then
            for z = 1, 60 do
                auraName, _, _, auraCount, _, auraDuration, auraExpirationTime, unitCaster, _, _, auraSpellID = UnitDebuff(unit, z, filter)
                if not auraSpellID or auraSpellID == spellID and (not sourceGUID or unitCaster and sourceGUID == UnitGUID(unitCaster)) then
                    break
                end
            end
        end
    end
    return auraName, auraCount, auraDuration, auraExpirationTime, auraSpellID, unitCaster
end

local function UpdateAura(aura, ...)
    local count, duration, expirationTime = ...
    if type(...) == "table" then
        local source = ...
        count, duration, expirationTime = source.count, source.duration, source.expirationTime
    end
    local time = GetTime()
    aura = aura or { start = time, pandemicDuration = duration }
    aura.count = count
    aura.expirationTime = expirationTime
    aura.duration = duration
    if expirationTime ~= aura.expirationTime then
        if aura.expirationTime - time >= aura.pandemicDuration * 0.3 then
            if duration < aura.duration * 1.3 then
                aura.pandemicDuration = round(duration / 1.3, 1)
            elseif duration > aura.duration * 1.3 then
                local minOriginalDuration = round(duration / 1.3, 1)
                if aura.expirationTime - time >= minOriginalDuration * 0.3 then
                    aura.pandemicDuration = minOriginalDuration
                else
                    aura.pandemicDuration = round(expirationTime - aura.expirationTime, 1)
                end
            end
        else
            aura.pandemicDuration = round(duration - (aura.expirationTime - time), 1)
        end
    end
    return aura
end

local function Cleanup(spellID)
    local currentTime = GetTime()
    for destGUID in pairs(Tracker.Auras) do
        for sourceGUID in pairs(Tracker.Auras[destGUID]) do
            if spellID then Tracker.Auras[destGUID][sourceGUID][spellID] = nil else
                for spellID, aura in pairs(Tracker.Auras[destGUID][sourceGUID]) do
                    if aura.expirationTime and aura.expirationTime < currentTime then
                        Tracker.Auras[destGUID][sourceGUID][spellID] = nil
                    end
                end
            end
            if next(Tracker.Auras[destGUID][sourceGUID]) == nil then
                Tracker.Auras[destGUID][sourceGUID] = nil
            end
        end
        if next(Tracker.Auras[destGUID]) == nil then
            Tracker.Auras[destGUID] = nil
        end
    end
end

local function MergeFilters(filterList)
    filterList = filterList or {}
    local HELPFUL, HARMFUL, PLAYER, RAID, CANCELABLE, NOT_CANCELABLE = "HELPFUL", "HARMFUL", "PLAYER", "RAID", "CANCELABLE", "NOT_CANCELABLE"
    for _, filter in pairs(filterList) do
        HELPFUL = filter and HELPFUL and filter:match(HELPFUL)
        HARMFUL = filter and HARMFUL and filter:match(HARMFUL)
        PLAYER = filter and PLAYER and filter:match(PLAYER)
        RAID = filter and RAID and filter:match(RAID)
        CANCELABLE = filter and CANCELABLE and filter:match(CANCELABLE)
        NOT_CANCELABLE = filter and NOT_CANCELABLE and filter:match(NOT_CANCELABLE)
    end
    local harmFilter = not (HELPFUL and HARMFUL) and (HELPFUL or HARMFUL)
    local cancelFilter = not (CANCELABLE and NOT_CANCELABLE) and (CANCELABLE or NOT_CANCELABLE)
    local filter = PLAYER
    filter = (filter and RAID and filter .. " " .. RAID) or filter or RAID
    filter = (filter and harmFilter and filter .. " " .. harmFilter) or filter or harmFilter
    filter = (filter and cancelFilter and filter .. " " .. cancelFilter) or filter or cancelFilter
    return filter or ""
end

local function CombatLogEventHandler(...)
    local timestamp, combatEventType, _, sourceGUID, _, sourceFlags, _, destGUID, _, destFlags, _, spellID, spellName = ...
    spellName = spellName and (type(spellName) == "string" and string.lower(spellName) or spellName)

    if Tracker.TrackedAuras[spellID] or Tracker.TrackedAuras[spellName] then
        SpellIDs[spellName] = SpellIDs[spellName] or {}
        SpellIDs[spellName][spellID] = true

        Tracker.LastTracked[spellID] = Tracker.LastTracked[spellID] or {}
        Tracker.LastTracked[spellID][sourceGUID] = Tracker.LastTracked[spellID][sourceGUID] or {}
        if Tracker.LastTracked[spellID][sourceGUID][combatEventType] == nil or Tracker.LastTracked[spellID][sourceGUID][combatEventType].timestamp ~= timestamp then
            Tracker.LastTracked[spellID][sourceGUID][combatEventType] = { timestamp = timestamp, unhandledGUIDs = {} }
        end

        local filter = combatEventType == "SPELL_PERIODIC_HEAL" and "HELPFUL"
                or combatEventType == "SPELL_PERIODIC_DAMAGE" and "HARMFUL"
                or combatEventType:match("SPELL_AURA") and (select(combatEventType == "SPELL_AURA_BROKEN_SPELL" and 18 or 15, ...) == "BUFF" and "HELPFUL" or "HARMFUL")
        if filter then
            if Tracker.LastTracked[spellID][sourceGUID][combatEventType].handled then
                if Tracker.LastTracked[spellID][sourceGUID][combatEventType].handled == -1 then
                    if Tracker.Auras[destGUID] and Tracker.Auras[destGUID][sourceGUID] then
                        Tracker.Auras[destGUID][sourceGUID][spellID] = nil
                    end
                else
                    Tracker.Auras[destGUID] = Tracker.Auras[destGUID] or {}
                    Tracker.Auras[destGUID][sourceGUID] = Tracker.Auras[destGUID][sourceGUID] or {}
                    Tracker.Auras[destGUID][sourceGUID][spellID] = UpdateAura(Tracker.Auras[destGUID][sourceGUID][spellID], Tracker.LastTracked[spellID][sourceGUID][combatEventType].handled)
                end
            else
                local unit = bit.band(destFlags, COMBATLOG_OBJECT_TARGET) > 0 and "target"
                        or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0 and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0 and "player"
                        or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0 and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PET) > 0 and "pet"
                        or bit.band(destFlags, COMBATLOG_OBJECT_FOCUS) > 0 and "focus"
                filter = filter and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0
                        and bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0 and filter .. " PLAYER" or filter
                if unit then
                    if Tracker.AuraFilters[spellID] and Tracker.AuraFilters[spellName] then
                        filter = filter .. " " .. MergeFilters({ Tracker.AuraFilters[spellName], Tracker.AuraFilters[spellID] })
                    elseif Tracker.AuraFilters[spellID] or Tracker.AuraFilters[spellName] then
                        filter = filter .. (Tracker.AuraFilters[spellID] or Tracker.AuraFilters[spellName])
                    end
                    local auraName, auraCount, auraDuration, auraExpirationTime = Check(unit, spellID, filter, sourceGUID, destGUID)

                    if auraName then
                        Tracker.Auras[destGUID] = Tracker.Auras[destGUID] or {}
                        Tracker.Auras[destGUID][sourceGUID] = Tracker.Auras[destGUID][sourceGUID] or {}
                        Tracker.Auras[destGUID][sourceGUID][spellID] = UpdateAura(Tracker.Auras[destGUID][sourceGUID][spellID], auraCount, auraDuration,
                            auraExpirationTime)
                        Tracker.LastTracked[spellID][sourceGUID][combatEventType].handled = Tracker.Auras[destGUID][sourceGUID][spellID]
                        for otherDestGUID in pairs(Tracker.LastTracked[spellID][sourceGUID][combatEventType].unhandledGUIDs) do
                            Tracker.Auras[otherDestGUID] = Tracker.Auras[destGUID] or {}
                            Tracker.Auras[otherDestGUID][sourceGUID] = Tracker.Auras[otherDestGUID][sourceGUID] or {}
                            Tracker.Auras[otherDestGUID][sourceGUID][spellID] = UpdateAura(Tracker.Auras[otherDestGUID][sourceGUID][spellID], Tracker.LastTracked[spellID][sourceGUID][combatEventType].handled)
                        end
                    else
                        if Tracker.Auras[destGUID] and Tracker.Auras[destGUID][sourceGUID] then
                            Tracker.Auras[destGUID][sourceGUID][spellID] = nil
                        end
                        Tracker.LastTracked[spellID][sourceGUID][combatEventType].handled = -1
                        for otherDestGUID in pairs(Tracker.LastTracked[spellID][sourceGUID][combatEventType].unhandledGUIDs) do
                            if Tracker.Auras[otherDestGUID] and Tracker.Auras[otherDestGUID][sourceGUID] then
                                Tracker.Auras[otherDestGUID][sourceGUID][spellID] = nil
                            end
                        end
                    end

                else
                    Tracker.LastTracked[spellID][sourceGUID][combatEventType].unhandledGUIDs[destGUID] = true
                end
            end
        end
    end
end





function Tracker:AuraTrack(aura, filter)
    aura = type(aura) == "string" and string.lower(aura) or aura
    if not self:AuraTracked(aura, filter) then
        Tracker.TrackedAuras[aura] = Tracker.TrackedAuras[aura] or {}
        self.TrackedAuras[aura] = filter and string.upper(filter) or ""
        Tracker.TrackedAuras[aura][self] = filter and string.upper(filter) or ""
        Tracker.AuraFilters[aura] = MergeFilters(Tracker.TrackedAuras[aura])
    end
end


function Tracker:AuraTracked(aura, filter)
    aura = type(aura) == "string" and string.lower(aura) or aura

    filter = filter and string.upper(filter) or self.TrackedAuras[aura]
    return (self.TrackedAuras[aura] and (self.TrackedAuras[aura] == filter or self.TrackedAuras[aura] == MergeFilters({ self.TrackedAuras[aura], filter }))) or (type(aura) == "number" and self:AuraTracked(GetSpellInfo(aura)))
end


function Tracker:AuraUntrack(aura)
    aura = type(aura) == "string" and string.lower(aura) or aura
    if self:AuraTracked(aura) then
        self.TrackedAuras[aura] = nil
        Tracker.TrackedAuras[aura][self] = nil
        if (next(Tracker.TrackedAuras[aura]) == nil) then
            Tracker.TrackedAuras[aura] = nil
            Tracker.AuraFilters[aura] = nil
            if type(aura) == "string" and SpellIDs[aura] then
                for spellID in pairs(SpellIDs[aura]) do
                    Cleanup(spellID)
                end
            else
                Cleanup(aura)
            end
        else
            Tracker.AuraFilters[aura] = MergeFilters(Tracker.TrackedAuras[aura])
        end
    end
end




function Tracker:GetFirst(destGUID, sourceGUID, spellID, spellName)
    if destGUID then
        if sourceGUID then
            if spellID then
                local foundAura = Tracker.Auras and Tracker.Auras[destGUID] and Tracker.Auras[destGUID][sourceGUID] and Tracker.Auras[destGUID][sourceGUID][spellID]
                foundAura = foundAura and foundAura[self] or foundAura
                if foundAura then return foundAura end
            elseif spellName and SpellIDs[spellName] then
                for spellID in pairs(SpellIDs[spellName]) do
                    local foundAura = self:GetFirst(destGUID, sourceGUID, spellID, spellName)
                    if foundAura then return foundAura end
                end
            elseif not spellName and Tracker.Auras[destGUID] and Tracker.Auras[destGUID][sourceGUID] then
                for spellID in pairs(Tracker.Auras[destGUID][sourceGUID]) do
                    local foundAura = self:GetFirst(destGUID, sourceGUID, spellID, spellName)
                    if foundAura then return foundAura end
                end
            end
        elseif Tracker.Auras[destGUID] then
            for sourceGUID in pairs(Tracker.Auras[destGUID]) do
                local foundAura = self:GetFirst(destGUID, sourceGUID, spellID, spellName)
                if foundAura then return foundAura end
            end
        end
    else
        for destGUID in pairs(Tracker.Auras) do
            local foundAura = self:GetFirst(destGUID, sourceGUID, spellID, spellName)
            if foundAura then return foundAura end
        end
    end
end

function Tracker:Get(destGUID, sourceGUID, spellID, spellName, found)
    found = found or {}

    if destGUID then
        if sourceGUID then
            if spellID then
                local foundAura = Tracker.Auras and Tracker.Auras[destGUID] and Tracker.Auras[destGUID][sourceGUID] and Tracker.Auras[destGUID][sourceGUID][spellID]
                foundAura = foundAura and foundAura[self] or foundAura
                if foundAura then
                    found[destGUID] = found[destGUID] or {}
                    found[destGUID][sourceGUID] = found[destGUID][sourceGUID] or {}
                    found[destGUID][sourceGUID][spellID] = foundAura
                end
            elseif spellName and SpellIDs[spellName] then
                for spellID in pairs(SpellIDs[spellName]) do
                    found = self:Get(destGUID, sourceGUID, spellID, spellName, found)
                end
            elseif not spellName and Tracker.Auras[destGUID] and Tracker.Auras[destGUID][sourceGUID] then
                for spellID in pairs(Tracker.Auras[destGUID][sourceGUID]) do
                    found = self:Get(destGUID, sourceGUID, spellID, spellName, found)
                end
            end
        elseif Tracker.Auras[destGUID] then
            for sourceGUID in pairs(Tracker.Auras[destGUID]) do
                found = self:Get(destGUID, sourceGUID, spellID, spellName, found)
            end
        end

    else
        for destGUID in pairs(Tracker.Auras) do
            found = self:Get(destGUID, sourceGUID, spellID, spellName, found)
        end
    end
    return found
end


function Tracker:SetAura(aura, info)
    aura = aura or {}
    aura.__index = aura
    aura[self] = aura[self] or setmetatable({}, aura)
    info = info or {}
    for key, value in pairs(info) do
        aura[self][key] = value
    end
    return aura
end

function Tracker:Set(destGUID, sourceGUID, spellID, spellName, info)
    if destGUID then
        Tracker.Auras[destGUID] = Tracker.Auras[destGUID] or {}
        if sourceGUID then
            Tracker.Auras[destGUID][sourceGUID] = Tracker.Auras[destGUID][sourceGUID] or {}
            if spellID then
                Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
            elseif SpellIDs[spellName] then
                for spellID in pairs(SpellIDs[spellName]) do
                    Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                end
            end
        else
            for sourceGUID in pairs(Tracker.Auras[destGUID]) do
                if spellID then
                    Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                elseif SpellIDs[spellName] then
                    for spellID in pairs(SpellIDs[spellName]) do
                        Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                    end
                end
            end
        end
    else
        for destGUID in pairs(Tracker.Auras) do
            if sourceGUID then
                Tracker.Auras[destGUID][sourceGUID] = Tracker.Auras[destGUID][sourceGUID] or {}
                if spellID then
                    Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                elseif SpellIDs[spellName] then
                    for spellID in pairs(SpellIDs[spellName]) do
                        Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                    end
                end
            else
                for sourceGUID in pairs(Tracker.Auras[destGUID]) do
                    if spellID then
                        Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                    elseif SpellIDs[spellName] then
                        for spellID in pairs(SpellIDs[spellName]) do
                            Tracker.Auras[destGUID][sourceGUID][spellID] = self:SetAura(Tracker.Auras[destGUID][sourceGUID][spellID], info)
                        end
                    end
                end
            end
        end
    end
end


function Tracker:AuraGetInfo(unit, aura, source, filter, getAll)
    local spellID = type(aura) == "number" and aura
    local spellName = GetSpellInfo(spellID) or aura
    spellName = spellName and spellName:lower()
    local destGUID = unit and (UnitGUID(unit) or unit)
    local sourceGUID = source and (UnitGUID(source) or source) or filter and type(filter) == "string" and string.upper(filter):match("PLAYER") and UnitGUID("player")
    if getAll then
        return self:Get(destGUID, sourceGUID, spellID, spellName)
    end
    return self:GetFirst(destGUID, sourceGUID, spellID, spellName)
end



function Tracker:AuraSetInfo(unit, aura, info, source, filter)
    local spellID = type(aura) == "number" and aura
    local spellName = GetSpellInfo(spellID) or aura
    spellName = spellName and spellName:lower()
    local destGUID = unit and (UnitGUID(unit) or unit)
    local sourceGUID = source and (UnitGUID(source) or source) or filter and type(filter) == "string" and string.upper(filter):match("PLAYER") and UnitGUID("player")
    self:Set(destGUID, sourceGUID, spellID, spellName, info)
end



--- Creates and returns a new aura tracker. Even if you do not set this new tracker to track any auras, it
-- can be used to interact with auras already being tracked by the library due to another tracker.
-- @return New tracker
-- @usage
-- Tracker = LibAuraTracker:New()
function LibAuraTracker:New()
    local tracker = setmetatable({ TrackedAuras = setmetatable({}, TrackedAurasMT) }, Tracker)
    Tracker.__index = Tracker
    return tracker
end




--- Attempts to check the total pandemic duration of an aura if it is already being tracked, and if not, starts tracking it.
-- @param unit Unit to check
-- @param aura Either name or id of the aura
-- @param source Optional source unitID or GUID to filter results
-- @param filter Optional filter to limit by
-- @return Total pandemic calculation duration of an aura
-- @usage
-- -- Get the pandemic calculation duration of your Rip on the target
-- RipPandemic = Tracker:AuraPandemic("target", "Rip", nil, "PLAYER HARMFUL")
-- RipPandemic = Tracker:AuraPandemic("target", "Rip", "player")
function Tracker:AuraPandemic(unit, aura, source, filter)
    self:Track(aura, filter)
    local spellID = type(aura) == "number" and aura
    local spellName = GetSpellInfo(spellID) or aura
    spellName = spellName and spellName:lower()
    local auraName, _, auraDuration, _, _, unitCaster = Check(unit, aura, filter)
    if not auraName then
        return 0
    end
    local auraInfo = self:AuraGetInfo(unit, aura, source or unitCaster and UnitGUID(unitCaster), filter)
    return auraInfo and auraInfo.pandemicDuration or auraDuration
end

--- Attempts to check the remaining percentage of an aura if it is already being tracked, and if not, starts tracking it.
-- @param unit Unit to check
-- @param aura Either name or id of the aura
-- @param source Optional source unitID or GUID to filter results
-- @param filter Optional filter to limit by
-- @return Percent of the pandemic calculation duration that remains of an aura
-- @usage
-- -- Get the percent ramaining of your Rip on the target
-- RipPercent = Tracker:AuraPercent("target", "Rip", nil, "PLAYER HARMFUL")
-- RipPercent = Tracker:AuraPercent("target", "Rip", "player")
function Tracker:AuraPercent(unit, aura, source, filter)
    self:Track(aura, filter)

    local spellID = type(aura) == "number" and aura
    local spellName = GetSpellInfo(spellID) or aura
    spellName = spellName and spellName:lower()
    local auraName, _, auraDuration, auraExpirationTime, _, unitCaster = Check(unit, aura, filter)
    if not auraName then
        return 0
    end
    local auraInfo = self:AuraGetInfo(unit, aura, source or unitCaster and UnitGUID(unitCaster), filter)
    auraExpirationTime = auraInfo and auraInfo.expirationTime or auraExpirationTime
    auraDuration = auraInfo and auraInfo.pandemicDuration or auraDuration
    return auraExpirationTime == 0 and 1 or ((auraExpirationTime - GetTime()) / auraDuration)
end





--- Attempts to find information about an aura or list of auras, if tracked
-- @param unit unitID or GUID to check
-- @param aura Name(s) or id(s) of the aura or auras to be tracked
-- @param source Optional source unitID or GUID to filter results
-- @param filter Optional filter to limit by
-- @param getAll Boolean to set to true for all results, not just the first
-- Will be in the form of a table in the following format:
-- Auras[destGUID][sourceGUID][spellID]
-- @return Current tracked aura information, if any
-- @usage
-- -- Get the aura information for your Rip on the target
-- RipInfo = Tracker:GetInfo("target", "Rip", "player")
-- -- Get the aura information for your Rip and Rake on the target
-- BleedInfo = Tracker:GetInfo("target", {"Rip", 155722}, "player")
-- -- Get the aura information for any Rip and Rake on the target
-- BleedInfo = Tracker:GetInfo("target", {"Rip", 155722})
-- -- Get the aura information for any Rip and Rake debuff on the target
-- BleedInfo = Tracker:GetInfo("target", {"Rip", 155722}, nil, "HARMFUL")
function Tracker:GetInfo(unit, aura, source, filter, getAll)


    if type(aura) == "table" then
        local auraInfo = {}
        for _, singleAura in pairs(aura) do
            auraInfo[singleAura] = self:AuraGetInfo(unit, singleAura, source, filter, getAll)
        end
        return auraInfo
    else
        return self:AuraGetInfo(unit, aura, source, filter, getAll)
    end
end




--- Updates tracked aura info
-- @param unit Unit to check
-- @param aura Name(s) or id(s) of the aura or auras to be tracked
-- @param info Table of key value pairs to set for the aura.
-- @param source Optional source unitID or GUID to filter results
-- @param filter Optional filter to limit by
-- @usage
-- -- Set some variable information for the Rip on your target
-- Tracker:SetInfo("target", "Rip", {variable=7, othervariable=8} "PLAYER HARMFUL")
-- -- Set some variable information for your Rip and Rake on the target
-- Tracker:SetInfo("target", {"Rip", 155722}, {variable=7, othervariable=8} "PLAYER HARMFUL")
function Tracker:SetInfo(unit, aura, info, source, filter)
    if type(aura) == "table" then
        for _, singleAura in pairs(aura) do
            self:AuraSetInfo(unit, singleAura, info, source, filter)
        end
    else
        self:AuraSetInfo(unit, aura, info, source, filter)
    end
end






--- Checks if the tracker is currently tracking an aura or all in a list of auras
-- @param aura Name(s) or id(s) of the aura or auras to be tracked
-- @param filter Optional filter to compare against existing filter, if any
-- @return Whether an aura or list of auras are all tracked
-- @usage
-- -- Looks for any auras with the name Rip are being tracked
-- RipTracked = Tracker:Tracked("Rip", "PLAYER HARMFUL")
-- -- Looks for the spellID for the DOT portion of Rake
-- -- If that isn't found, checks to see if all auras named Rake are tracked.
-- -- If that is true, then this aura is being tracked
-- RakeTracked = Tracker:Tracked(155722, "PLAYER HARMFUL")
-- -- Looks for both Rip and the DOT portion of Rake
-- BleedsTracked = Tracker:Tracked({ "Rip", 155722 }, "PLAYER HARMFUL")
function Tracker:Tracked(aura, filter)
    if type(aura) == "table" then
        for _, singleAura in pairs(aura) do
            if not self:AuraTracked(aura, singleAura) then return false
            end
        end
        return true
    else
        return self:AuraTracked(aura, filter)
    end
end

--- Checks if the tracker is currently tracking an aura or any in a list of auras
-- @param aura Name(s) or id(s) of the aura or auras to be tracked
-- @param filter Optional filter to compare against existing filter, if any
-- @return Whether an aura or any in a list of auras are tracked
-- @usage
-- -- Looks for either Rip or the DOT portion of Rake
-- AnyBleedsTracked = Tracker:TrackedAny({ "Rip", 155722 }, "PLAYER HARMFUL")
function Tracker:TrackedAny(aura, filter)
    if type(aura) == "table" then
        for _, singleAura in pairs(aura) do
            if self:AuraTracked(aura, singleAura) then return true
            end
        end
        return false
    else
        return self:AuraTracked(aura, filter)
    end
end

--- Tells the tracker to start tracking an aura or auras
-- @param aura Name(s) or id(s) of the aura or auras to be tracked
-- @param filter Optional filter to use when calling the UnitAura function
-- @return self to allow for chaining tracking in a single line
-- @usage
-- -- Start tracking Rip
-- Tracker:Track("Rip", "PLAYER HARMFUL")
-- -- Start tracking Rip and the DOT portion of Rake
-- Tracker:Track({ "Rip", 155722 }, "PLAYER HARMFUL")
-- -- Start tracking Rip and Berserk
-- Tracker:Track("Rip", "PLAYER HARMFUL"):Track("Berserk", "PLAYER HELPFUL")
function Tracker:Track(aura, filter)
    if type(aura) == "table" then
        for _, singleAura in pairs(aura) do
            self:AuraTrack(singleAura, filter)
        end
    else
        self:AuraTrack(aura, filter)
    end
    return self
end


--- Tells the tracker to stop tracking an aura or auras
-- @param aura Name(s) or id(s) of the aura or auras to be tracked
-- @usage
-- -- Stop tracking Rip
-- Tracker:Untrack("Rip")
-- -- Stop tracking Rip and the DOT portion of Rake and Berserk
-- Tracker:Untrack({ "Rip", 155722, "Berserk" })
function Tracker:Untrack(aura)
    if type(aura) == "table" then
        for _, singleAura in pairs(aura) do
            self:AuraUntrack(singleAura)
        end
    else
        self:AuraUntrack(aura)
    end
end


--- Tells the tracker to stop tracking all auras
-- @usage
-- Tracker:Wipe()
function Tracker:Wipe()
    for aura in pairs(self.TrackedAuras) do
        self:Untrack(aura)
    end
end



Frame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        CombatLogEventHandler(...)
    end
    Cleanup()
end);
Frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED");

