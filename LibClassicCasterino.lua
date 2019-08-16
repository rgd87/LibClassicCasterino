--[================[
LibClassicCasterino
Author: d87
--]================]


local MAJOR, MINOR = "LibClassicCasterino", 3
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
local CastingInfo = CastingInfo
local ChannelInfo = ChannelInfo

local COMBATLOG_OBJECT_TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER
local classCasts
local classChannels
local talentDecreased
local FireToUnits

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
            if isSrcPlayer and classChannels[spellID] then
                -- SPELL_CAST_SUCCESS can come right after AURA_APPLIED, so ignoring it
                return
            end
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

-- local castTimeIncreases = {
--     [1714] = 60,    -- Curse of Tongues (60%)
--     [5760] = 60,    -- Mind-Numbing Poison (60%)
-- }
local function IsSlowedDown(unit)
    for i=1,16 do
        local name, _, _, _, _, _, _, _, _, spellID = UnitAura(unit, i, "HARMFUL")
        if not name then return end
        if spellID == 1714 or spellID == 5760 then
            return true
        end
    end
end

function lib:UnitCastingInfo(unit)
    if unit == "player" then return CastingInfo() end
    local guid = UnitGUID(unit)
    local cast = casters[guid]
    if cast then
        local castType, name, icon, startTimeMS, endTimeMS, spellID = unpack(cast)
        if IsSlowedDown(unit) then
            local duration = endTimeMS - startTimeMS
            endTimeMS = startTimeMS + duration * 1.6
        end
        if castType == "CAST" and endTimeMS > GetTime()*1000 then
            local castID = nil
            return name, nil, icon, startTimeMS, endTimeMS, nil, castID, false, spellID
        end
    end
end

function lib:UnitChannelInfo(unit)
    if unit == "player" then return ChannelInfo() end
    local guid = UnitGUID(unit)
    local cast = casters[guid]
    if cast then
        local castType, name, icon, startTimeMS, endTimeMS, spellID = unpack(cast)
        -- Curse of Tongues doesn't matter that much for channels, skipping
        if castType == "CHANNEL" and endTimeMS > GetTime()*1000 then
            return name, nil, icon, startTimeMS, endTimeMS, nil, false, spellID
        end
    end
end


local Passthrough = function(self, event, unit)
    if unit == "player" then
        callbacks:Fire(event, unit)
    end
end
f.UNIT_SPELLCAST_START = Passthrough
f.UNIT_SPELLCAST_DELAYED = Passthrough
f.UNIT_SPELLCAST_STOP = Passthrough
f.UNIT_SPELLCAST_FAILED = Passthrough
f.UNIT_SPELLCAST_INTERRUPTED = Passthrough
f.UNIT_SPELLCAST_CHANNEL_START = Passthrough
f.UNIT_SPELLCAST_CHANNEL_UPDATE = Passthrough
f.UNIT_SPELLCAST_CHANNEL_STOP = Passthrough

function callbacks.OnUsed()
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

    f:RegisterEvent("UNIT_SPELLCAST_START")
    f:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    f:RegisterEvent("UNIT_SPELLCAST_STOP")
    f:RegisterEvent("UNIT_SPELLCAST_FAILED")
    f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

    -- for unit lookup
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
end

function callbacks.OnUnused()
    f:UnregisterAllEvents()
end

talentDecreased = {
    [25311] = 0.8,    -- Corruption (while leveling)
    [17924] = 2,       -- Soul Fire
    [25307] = 0.5,      -- Shadow Bolt
    [25309] = 0.5,      -- Immolate
    [691] = 4,        -- Summon Felhunter
    [688] = 4,        -- Summon Imp
    [697] = 4,        -- Summon Voidwalker
    [712] = 4,        -- Summon Succubus

    [15208] = 1,        -- Lightning Bolt
    [10605] = 1,        -- Chain Lightning
    [25357] = 0.5,      -- Healing Wave
    [2645] = 2,       -- Ghost Wolf

    [25304] = 0.5,      -- Frostbolt
    [25306] = 0.5,      -- Fireball


    [10934] = 0.5,      -- Smite
    [15261] = 0.5,    -- Holy Fire
    [6064] = 0.5,     -- Heal
    [25314] = 0.5,    -- Greater Heal
    [10876] = 0.5,     -- Mana Burn

    [9912] = 0.5,     -- Wrath
    [25298] = 0.5,     -- Starfire
    [25297] = 0.5,     -- Healing Touch
}

classCasts = {
    [25311] = 2, -- Corruption
    [6215] = 1.5, -- Fear
    [17928] = 2, -- Howl of Terror
    [18647] = 1.5, -- Banish
    [6366] = 3, -- Create Firestone (Lesser)
    [17951] = 3, -- Create Firestone
    [17952] = 3, -- Create Firestone (Greater)
    [17953] = 3, -- Create Firestone (Major)
    [28023] = 3, -- Create Healthstone
    [11729] = 3, -- Create Healthstone (Greater)
    [6202] = 3, -- Create Healthstone (Lesser)
    [11730] = 3, -- Create Healthstone (Major)
    [6201] = 3, -- Create Healthstone (Minor)
    [20755] = 3, -- Create Soulstone
    [20756] = 3, -- Create Soulstone (Greater)
    [20752] = 3, -- Create Soulstone (Lesser)
    [20757] = 3, -- Create Soulstone (Major)
    [693] = 3, -- Create Soulstone (Minor)
    [2362] = 5, -- Create Spellstone
    [17727] = 5, -- Create Spellstone (Greater)
    [17728] = 5, -- Create Spellstone (Major)
    [11726] = 3, -- Enslave Demon
    [126] = 5, -- Eye of Kilrogg
    [1122] = 2, -- Inferno
    [23161] = 3, -- Summon Dreadsteed
    [5784] = 3, -- Summon Felsteed
    [691] = 10, -- Summon Felhunter
    [688] = 10, -- Summon Imp
    [697] = 10, -- Summon Voidwalker
    [712] = 10, -- Summon Succubus
    [25309] = 2, -- Immolate
    [17923] = 1.5, -- Searing Pain
    [25307] = 3, -- Shadow Bolt
    [17924] = 4, -- Soul Fire

    [9853] = 1.5, -- Entangling Roots
    [18658] = 1.5, -- Hibernate
    [9901] = 1.5, -- Soothe Animal
    [25298] = 3.5, -- Starfire
    [18960] = 10, -- Teleport: Moonglade
    [9912] = 2, -- Wrath
    [25297] = 3.5, -- Healing Touch
    [20748] = 2, -- Rebirth
    [9858] = 2, -- Regrowth

    [28612] = 3, -- Conjure Food
    [759] = 3, -- Conjure Mana Agate
    [10053] = 3, -- Conjure Mana Citrine
    [3552] = 3, -- Conjure Mana Jade
    [10054] = 3, -- Conjure Mana Ruby
    [10140] = 3, -- Conjure Water
    [12826] = 1.5, -- Polymorph
    [28270] = 1.5, -- Polymorph: Cow
    [25306] = 3.5, -- Fireball
    [10216] = 3, -- Flamestrike
    [10207] = 1.5, -- Scorch
    [25304] = 3, -- Frostbolt

    [10876] = 3, -- Mana Burn
    [10955] = 1.5, -- Shackle Undead
    [10917] = 1.5, -- Flash Heal
    [25314] = 3, -- Greater Heal
    [6064] = 3, -- Heal
    [15261] = 3.5, -- Holy Fire
    [2053] = 2.5, -- Lesser Heal
    [25316] = 3, -- Prayer of Healing
    [20770] = 10, -- Resurrection
    [10934] = 2.5, -- Smite
    [10947] = 1.5, -- Mind Blast
    [10912] = 3, -- Mind Control

    [19943] = 1.5, -- Flash of Light
    [24239] = 1, -- Hammer of Wrath
    [25292] = 2.5, -- Holy Light
    [10318] = 2, -- Holy Wrath
    [20773] = 10, -- Redemption
    [23214] = 3, -- Summon Charger
    [13819] = 3, -- Summon Warhorse
    [10326] = 1.5, -- Turn Undead

    [10605] = 2.5, -- Chain Lightning
    [15208] = 3, -- Lightning Bolt
    [556] = 10, -- Astral Recall
    [6196] = 2, -- Far Sight
    [2645] = 3, -- Ghost Wolf
    [20777] = 10, -- Ancestral Spirit
    [10623] = 2.5, -- Chain Heal
    [25357] = 3, -- Healing Wave
    [10468] = 1.5, -- Lesser Healing Wave

    [1842] = 2, -- Disarm Trap
    -- missing poison creation

    [11605] = 1.5, -- Slam

    [20904] = 3, -- Aimed Shot
    [1002] = 2, -- Eyes of the Beast
    [2641] = 5, -- Dismiss pet
    [982] = 10, -- Revive Pet
    [14327] = 1.5, -- Scare Beast

    [8690] = 10, -- Hearthstone
    [4068] = 1, -- Iron Grenade

    -- Munts do not generate SPELL_CAST_START
    -- [8394] = 3, -- Striped Frostsaber
    -- [10793] = 3, -- Striped Nightsaber
}

classChannels = {
    -- [18807] = 3, -- Mind Flay

    [746] = 7,      -- First Aid
    [13278] = 4,    -- Gnomish Death Ray
    [20577] = 10,   -- Cannibalize
    [19305] = 6,    -- Starshards

    -- DRUID
    [17402] = 9.5,  -- Hurricane
    [9863] = 9.5,      -- Tranquility

    -- HUNTER
    [6197] = 60,     -- Eagle Eye
    [13544] = 5,     -- Mend Pet
    [1515] = 20,     -- Tame Beast
    [1002] = 60,     -- Eyes of the Beast
    [14295] = 6,     -- Volley

    -- MAGE
    [25345] = 5,     -- Arcane Missiles
    [10187] = 8,     -- Blizzard
    [12051] = 8,     -- Evocation

    -- PRIEST
    [18807] = 3,    -- Mind Flay
    [2096] = 60,    -- Mind Vision
    [10912] = 3,    -- Mind Control

    -- WARLOCK
    [126] = 45,       -- Eye of Kilrogg
    [11700] = 4.5,    -- Drain Life
    [11704] = 4.5,    -- Drain Mana
    [11675] = 14.5,   -- Drain Soul
    [11678] = 7.5,    -- Rain of Fire
    [11684] = 15,     -- Hellfire
    [11695] = 10,     -- Health Funnel
}

for id in pairs(classCasts) do
    spellNameToID[GetSpellInfo(id)] = id
    -- AddSpellNameRecognition(id)
end
for id in pairs(classChannels) do
    spellNameToID[GetSpellInfo(id)] = id
    -- AddSpellNameRecognition(id)
end

local partyGUIDtoUnit = {}
local raidGUIDtoUnit = {}
local nameplateUnits = {}
local commonUnits = {
    -- "player",
    "target",
    "targettarget",
    "pet",
}

function f:NAME_PLATE_UNIT_ADDED(event, unit)
    nameplateUnits[unit] = true
end


function f:NAME_PLATE_UNIT_REMOVED(event, unit)
    nameplateUnits[unit] = nil
end

function f:GROUP_ROSTER_UPDATE()
    table.wipe(partyGUIDtoUnit)
    table.wipe(raidGUIDtoUnit)
    if IsInGroup() then
        for i=1,4 do
            local unit = "party"..i
            local guid = UnitGUID(unit)
            partyGUIDtoUnit[guid] = unit
        end
    end
    if IsInRaid() then
        for i=1,40 do
            local unit = "raid"..i
            local guid = UnitGUID(unit)
            raidGUIDtoUnit[guid] = unit
        end
    end
end

FireToUnits = function(event, guid, ...)
    for _, unit in ipairs(commonUnits) do
        if UnitGUID(unit) == guid then
            callbacks:Fire(event, unit, ...)
        end
    end

    local partyUnit = partyGUIDtoUnit[guid]
    if partyUnit then
        callbacks:Fire(event, partyUnit, ...)
    end

    local raidUnit = raidGUIDtoUnit[guid]
    if raidUnit then
        callbacks:Fire(event, raidUnit, ...)
    end

    for unit in pairs(nameplateUnits) do
        if UnitGUID(unit) == guid then
            callbacks:Fire(event, unit, ...)
        end
    end
end