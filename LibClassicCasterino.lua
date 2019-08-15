--[================[
LibTargetedCasts
Author: d87
--]================]


local MAJOR, MINOR = "LibClassicCasterino", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end


lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

lib.frame = lib.frame or CreateFrame("Frame")

local f = lib.frame
local callbacks = lib.callbacks

lib.casters = lib.casters or {} -- setmetatable({}, { __mode = "v" })
local casters = lib.casters

-- local guidsToPurge = {}

local UnitGUID = UnitGUID
local bit_band = bit.band
local GetTime = GetTime
-- local tinsert = tinsert

local COMBATLOG_OBJECT_TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER
local AllUnitIDs
local classCasts
local classChannels
local talentDecreased

f:SetScript("OnEvent", function(self, event, ...)
    return self[event](self, event, ...)
end)


local spellNameToID = {}

local castTimeCache = {}
local castTimeCacheStartTimes = setmetatable({}, { __mode = "v" })

-- local SpellMixin = _G.Spell
-- local AddSpellNameRecognition = function(lastRankID)
--     local spellObj = SpellMixin:CreateFromSpellID(lastRankID)
--     spellObj:ContinueOnSpellLoad(function()
--         local spellName = spellObj:GetSpellName()
--         spellNameToID[spellName] = lastRankID
--     end)
-- end

local refreshCastTable = function(tbl, ...)
    local numArgs = select("#", ...)
    for i=1, numArgs do
        tbl[i] = select(i, ...)
    end
end

local function FireToUnits(event, guid, ...)
    for _, unit in ipairs(AllUnitIDs) do
        if UnitGUID(unit) == guid then
            callbacks:Fire(event, unit, ...)
        end
    end
end

local makeCastUID = function(guid, spellName)
    local _, _, _, _, _, npcID = strsplit("-", guid);
    return npcID..spellName
end

local function CastStart(srcGUID, castType, spellName, spellID, overrideCastTime )
    local _, _, icon, castTime = GetSpellInfo(spellID)
    if castType == "CHANNEL" then
        castTime = classChannels[spellID]*1000
        local decreased = talentDecreased[spellID]
        if decreased then
            castTime = castTime - decreased
        end
    end
    if overrideCastTime then
        castTime = overrideCastTime
    end
    local now = GetTime()*1000
    local startTime = now
    local endTime = now + castTime
    local currentCast = casters[srcGUID]

    if currentCast then
        refreshCastTable(currentCast, castType, spellName, icon, startTime, endTime, spellID )
    else
        casters[srcGUID] = { castType, spellName, icon, startTime, endTime, spellID }
    end


    if castType == "CAST" then
        FireToUnits("UNIT_SPELLCAST_START", srcGUID)
    else
        FireToUnits("UNIT_SPELLCAST_CHANNEL_START", srcGUID)
    end
end

local function CastStop(srcGUID, castType, suffix )
    local currentCast = casters[srcGUID]
    if currentCast then
        castType = castType or currentCast[1]

        casters[srcGUID] = nil

        if castType == "CAST" then
            local event = "UNIT_SPELLCAST_"..suffix
            FireToUnits(event, srcGUID)
        else
            FireToUnits("UNIT_SPELLCAST_CHANNEL_STOP", srcGUID)
        end
    end
end

function f:COMBAT_LOG_EVENT_UNFILTERED(event)

    local timestamp, eventType, hideCaster,
    srcGUID, srcName, srcFlags, srcFlags2,
    dstGUID, dstName, dstFlags, dstFlags2,
    spellID, spellName, arg3, arg4, arg5 = CombatLogGetCurrentEventInfo()

    local isSrcPlayer = bit_band(srcFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0
    if isSrcPlayer and spellID == 0 then
        spellID = spellNameToID[spellName]
    end
    if eventType == "SPELL_CAST_START" then
        if isSrcPlayer then
            local isCasting = classCasts[spellID]
            if isCasting then
                CastStart(srcGUID, "CAST", spellName, spellID)
            end
        else
            local castUID = makeCastUID(srcGUID, spellName)
            local cachedTime = castTimeCache[castUID]
            local spellID = 2050 -- just for the icon
            if cachedTime then
                CastStart(srcGUID, "CAST", spellName, spellID, cachedTime*1000)
            else
                castTimeCacheStartTimes[srcGUID..castUID] = GetTime()
                CastStart(srcGUID, "CAST", spellName, spellID, 1500) -- using default 1.5s cast time for now
            end
        end
    elseif eventType == "SPELL_CAST_FAILED" then

            CastStop(srcGUID, "CAST", "FAILED")

    elseif eventType == "SPELL_CAST_SUCCESS" then
            if not isSrcPlayer then
                local castUID = makeCastUID(srcGUID, spellName)
                local cachedTime = castTimeCache[castUID]
                if not cachedTime then
                    local restoredStartTime = castTimeCacheStartTimes[srcGUID..castUID]
                    if restoredStartTime then
                        local now = GetTime()
                        local castTime = now - restoredStartTime
                        if castTime < 10 then
                            castTimeCache[castUID] = castTime
                        end
                    end
                end
            end
            CastStop(srcGUID, nil, "STOP")

    elseif eventType == "SPELL_INTERRUPT" then

            CastStop(dstGUID, nil, "INTERRUPTED")

    elseif  eventType == "SPELL_AURA_APPLIED" or
            eventType == "SPELL_AURA_REFRESH" or
            eventType == "SPELL_AURA_APPLIED_DOSE"
    then
        if isSrcPlayer then
            local isChanneling = classChannels[spellID]
            if isChanneling then
                CastStart(srcGUID, "CHANNEL", spellName, spellID)
            end
        end
    elseif eventType == "SPELL_AURA_REMOVED" then
        if isSrcPlayer then
            local isChanneling = classChannels[spellID]
            if isChanneling then
                CastStop(srcGUID, "CHANNEL", "STOP")
            end
        end
    end

end

function lib:UnitCastingInfo(unit)
    local guid = UnitGUID(unit)
    local cast = casters[guid]
    if cast then
        local castType, name, icon, startTimeMS, endTimeMS, spellID = unpack(cast)
        if castType == "CAST" and endTimeMS > GetTime()*1000 then
            local castID = nil
            return name, nil, icon, startTimeMS, endTimeMS, nil, castID, false, spellID
        end
    end
end

function lib:UnitChannelInfo(unit)
    local guid = UnitGUID(unit)
    local cast = casters[guid]
    if cast then
        local castType, name, icon, startTimeMS, endTimeMS, spellID = unpack(cast)
        if castType == "CHANNEL" and endTimeMS > GetTime()*1000 then
            return name, nil, icon, startTimeMS, endTimeMS, nil, false, spellID
        end
    end
end

function callbacks.OnUsed()
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

function callbacks.OnUnused()
    f:UnregisterAllEvents()
end

talentDecreased = { -- from ClassicCastbars
    [403] = 1,        -- Lightning Bolt
    [421] = 1,        -- Chain Lightning
    [6353] = 2,       -- Soul Fire
    [116] = 0.5,      -- Frostbolt
    [133] = 0.5,      -- Fireball
    [686] = 0.5,      -- Shadow Bolt
    [348] = 0.5,      -- Immolate
    [331] = 0.5,      -- Healing Wave
    [585] = 0.5,      -- Smite
    [14914] = 0.5,    -- Holy Fire
    [2054] = 0.5,     -- Heal
    [25314] = 0.5,    -- Greater Heal
    [8129] = 0.5,     -- Mana Burn
    [5176] = 0.5,     -- Wrath
    [2912] = 0.5,     -- Starfire
    [5185] = 0.5,     -- Healing Touch
    [2645] = 2,       -- Ghost Wolf
    [691] = 4,        -- Summon Felhunter
    [688] = 4,        -- Summon Imp
    [697] = 4,        -- Summon Voidwalker
    [712] = 4,        -- Summon Succubus
}

classCasts = {
    [2060] = true, -- Greater Heal
}

classChannels = {
    [15407] = 3, -- Mind Flay
}

for id in pairs(classCasts) do
    spellNameToID[GetSpellInfo(id)] = id
    -- AddSpellNameRecognition(id)
end
for id in pairs(classChannels) do
    spellNameToID[GetSpellInfo(id)] = id
    -- AddSpellNameRecognition(id)
end

AllUnitIDs = {
    "player",
    "target",
    "targettarget",
    "pet",
    "party1", "party1pet",
    "party2", "party2pet",
    "party3", "party3pet",
    "party4", "party4pet",
    "raid1",
    "raid2",
    "raid3",
    "raid4",
    "raid5",
    "raid6",
    "raid7",
    "raid8",
    "raid9",
    "raid10",
    "raid11",
    "raid12",
    "raid13",
    "raid14",
    "raid15",
    "raid16",
    "raid17",
    "raid18",
    "raid19",
    "raid20",
    "raid21",
    "raid22",
    "raid23",
    "raid24",
    "raid25",
    "raid26",
    "raid27",
    "raid28",
    "raid29",
    "raid30",
    "raid31",
    "raid32",
    "raid33",
    "raid34",
    "raid35",
    "raid36",
    "raid37",
    "raid38",
    "raid39",
    "raid40",

    "nameplate1",
    "nameplate2",
    "nameplate3",
    "nameplate4",
    "nameplate5",
    "nameplate6",
    "nameplate7",
    "nameplate8",
    "nameplate9",
    "nameplate10",
    "nameplate11",
    "nameplate12",
    "nameplate13",
    "nameplate14",
    "nameplate15",
}