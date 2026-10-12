-- Quencher: Molten Core douse tracker
-- Based on Tattler by MarcelineVQ (LGPL v2.1), reduced to the Molten Core douse feature.
-- Requires SuperWoW. HearthDB (SQLite) is optional: without it only the WTF file is used.
-- Lua 5.0 syntax (vanilla client).

if not SetAutoloot then
  DEFAULT_CHAT_FRAME:AddMessage("[|cff00ff00Quencher|r] requires |cffffd200SuperWoW|r to operate.")
  return
end

local ADDON = "Quencher"
local ZONE = "Molten Core"
local MAX_DOUSES = 7
local DOUSE_SPELLS = { [21358] = true, [45304] = true }  -- Rune of the Firelord (from Tattler)
local DEFAULT_RETENTION_DAYS = 14
local DB_FILE = "Quencher.db"          -- created in <WoW>/CustomData/
local PREFIX = "Quencher"
local TRIGGERS = { ["!douse"] = true, ["!douses"] = true }  -- raid chat commands
local DEBUG_MODE = false

local Quencher = CreateFrame("Frame", "Quencher")

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------
local function out(msg) DEFAULT_CHAT_FRAME:AddMessage("[|cff00ff00Quencher|r] "..tostring(msg)) end
local function dbg(msg) if DEBUG_MODE then out(msg) end end
local function esc(s) return (string.gsub(tostring(s), "'", "''")) end

local CLASS_COLORS = {
  HUNTER="ffabd473", WARLOCK="ff9482c9", PRIEST="ffffffff", PALADIN="fff58cba",
  MAGE="ff69ccf0", ROGUE="fffff569", DRUID="ffff7d0a", SHAMAN="ff0070de", WARRIOR="ffc79c6e",
}
local function ColorizeName(unit)
  local _, c = UnitClass(unit)
  local hex = (c and CLASS_COLORS[c]) or "ffc0c0c0"
  return "|c"..hex..(UnitName(unit) or "?").."|r"
end

------------------------------------------------------------------
-- SQLite (HearthDB). Every call is pcall-protected; failures only disable SQL.
------------------------------------------------------------------
local db = nil

local function dbExec(sql)
  if not db then return false end
  local ok, err = pcall(HDB_Execute, db, sql)
  if not ok then dbg("SQL error: "..tostring(err)); return false end
  return true
end

local function dbTx(sql)   -- several statements as one atomic commit
  if not dbExec("BEGIN; "..sql.." COMMIT;") then
    if db then pcall(HDB_Execute, db, "ROLLBACK") end
    return false
  end
  return true
end

local function dbQuery(sql)
  if not db then return {} end
  local ok, rows = pcall(HDB_Query, db, sql)
  if ok and rows then return rows end
  dbg("SQL query error: "..tostring(rows))
  return {}
end

local function DbInit()
  if not HDB_GetVersion then return end
  local ok, h = pcall(HDB_Open, DB_FILE)
  if not ok then out("HearthDB open failed: "..tostring(h)); return end
  db = h
  dbExec([[
    CREATE TABLE IF NOT EXISTS raid (
      raid_id INTEGER PRIMARY KEY, created INTEGER NOT NULL, updated INTEGER NOT NULL, count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS douse (
      raid_id INTEGER NOT NULL, seq INTEGER NOT NULL, caster TEXT, ts INTEGER NOT NULL,
      PRIMARY KEY (raid_id, seq)
    );
  ]])
end

-- Delete raids (and their douses) not updated within the retention period.
local function Purge()
  local days = QuencherDB.retention_days or DEFAULT_RETENTION_DAYS
  local cutoff = time() - days * 86400
  dbTx("DELETE FROM douse WHERE raid_id IN (SELECT raid_id FROM raid WHERE updated < "..cutoff.."); "
     .."DELETE FROM raid WHERE updated < "..cutoff..";")
end

------------------------------------------------------------------
-- Raid ID and progress (WTF file keeps the original douse_tracking = { id, count })
------------------------------------------------------------------
local function RaidId()
  for i = 1, GetNumSavedInstances() do
    local name, id = GetSavedInstanceInfo(i)
    if name == ZONE then return id end
  end
  return nil
end

local function SyncCount(id, count, caster)
  local d = QuencherDB.douse_tracking
  if d.id ~= id then d.id = id; d.count = 0 end
  if count > MAX_DOUSES then count = MAX_DOUSES end
  if count > d.count then d.count = count end
  local now = time()
  dbTx("INSERT OR IGNORE INTO raid (raid_id, created, updated, count) VALUES ("..id..","..now..","..now..",0); "
     .."INSERT OR IGNORE INTO douse (raid_id, seq, caster, ts) VALUES ("..id..","..count..",'"..esc(caster or "?").."',"..now.."); "
     .."UPDATE raid SET count="..d.count..", updated="..now.." WHERE raid_id="..id..";")
end

local function RecordDouse(id, casterName)
  local d = QuencherDB.douse_tracking
  if d.id ~= id then d.id = id; d.count = 0 end
  local n = d.count + 1
  if n > MAX_DOUSES then n = MAX_DOUSES end
  SyncCount(id, n, casterName)
  return QuencherDB.douse_tracking.count
end

local function ProgressLines()
  local d = QuencherDB.douse_tracking
  local id = RaidId() or d.id
  if not id or id == 0 then return nil, { "No Molten Core lockout found yet." } end
  local lines = {}
  local count = (d.id == id) and d.count or 0
  table.insert(lines, format("Molten Core raid ID %s: %d/%d runes doused", tostring(id), count, MAX_DOUSES))
  local rows = dbQuery("SELECT seq, caster, ts FROM douse WHERE raid_id="..id.." ORDER BY seq")
  for i = 1, table.getn(rows) do
    table.insert(lines, format("  %s. %s (%s)", rows[i].seq, rows[i].caster or "?", date("%H:%M", tonumber(rows[i].ts) or 0)))
  end
  return id, lines
end

local function PrintProgress(channel)
  local _, lines = ProgressLines()
  for i = 1, table.getn(lines) do
    if channel then SendChatMessage(lines[i], channel) else out(lines[i]) end
  end
end

------------------------------------------------------------------
-- Announcements (one client per douse announces, like Tattler)
------------------------------------------------------------------
local function Announce(caster, count)
  SendChatMessage(format("[%s] has doused a Rune of the Firelord %d/%d", ColorizeName(caster), count, MAX_DOUSES), "RAID")
end

local pending = {}   -- key -> { elapsed, copies = { {sender, count, caster, raid} } }

local function Pump()
  local dt = arg1
  for key, data in pairs(pending) do
    data.elapsed = data.elapsed + dt
    if data.elapsed > 0.3 then
      local best, maxCount = nil, 0
      for _, c in ipairs(data.copies) do
        if not best or c.sender < best.sender then best = c end   -- lowest sender name announces
        if c.count > maxCount then maxCount = c.count end
      end
      SyncCount(best.raid, maxCount, UnitName(best.caster) or best.caster)
      if best.sender == UnitName("player") then Announce(best.caster, maxCount) end
      pending[key] = nil
    end
  end
  if not next(pending) then Quencher:SetScript("OnUpdate", nil) end
end

------------------------------------------------------------------
-- Events
------------------------------------------------------------------
function Quencher.UNIT_CASTEVENT(caster, target, action, spell_id)
  if not DOUSE_SPELLS[spell_id] then return end
  target = target or ""
  if string.sub(caster, 3, 3) == "F" then return end      -- mobs
  if string.sub(target, 3, 3) == "F" then return end
  if caster == target then return end
  if action ~= "CAST" or not UnitInRaid(caster) then return end

  local id = RaidId()
  if not id then dbg("douse seen but no Molten Core lockout"); return end
  local count = RecordDouse(id, UnitName(caster))
  SendAddonMessage(PREFIX, format("%d:%s,%d,%d", spell_id, caster, count, id), "RAID")
end

function Quencher.CHAT_MSG_ADDON(prefix, msg, channel, sender)
  if prefix ~= PREFIX then return end
  local _, _, spell_id, caster, count, id = string.find(msg, "^(%d+):(%w+),(%d+),(%d+)$")
  if not spell_id then return end
  local key = spell_id..caster..id..count
  pending[key] = pending[key] or { elapsed = 0, copies = {} }
  table.insert(pending[key].copies, { sender = sender, count = tonumber(count), caster = caster, raid = tonumber(id) })
  Quencher:SetScript("OnUpdate", Pump)
end

function Quencher.ADDON_LOADED(name)
  if name ~= ADDON then return end
  QuencherDB = QuencherDB or {}
  QuencherDB.douse_tracking = QuencherDB.douse_tracking or { id = 0, count = 0 }
  QuencherDB.retention_days = QuencherDB.retention_days or DEFAULT_RETENTION_DAYS
  DbInit()
  Purge()
  RequestRaidInfo()
end

-- fight ended: refresh lockout info in case a boss kill created/changed the raid ID
function Quencher.PLAYER_REGEN_ENABLED()
  if GetRealZoneText() == ZONE then RequestRaidInfo() end
end

function Quencher.UPDATE_INSTANCE_INFO()
  if GetNumSavedInstances() == 0 then
    QuencherDB.douse_tracking = { id = 0, count = 0 }
  end
end

local function OnChat(msg, sender)
  if TRIGGERS[string.lower(msg or "")] and sender == UnitName("player") then PrintProgress("RAID") end
end
function Quencher.CHAT_MSG_RAID(msg, sender) OnChat(msg, sender) end
function Quencher.CHAT_MSG_RAID_LEADER(msg, sender) OnChat(msg, sender) end
function Quencher.CHAT_MSG_RAID_WARNING(msg, sender) OnChat(msg, sender) end

Quencher:RegisterEvent("ADDON_LOADED")
Quencher:RegisterEvent("UNIT_CASTEVENT")
Quencher:RegisterEvent("CHAT_MSG_ADDON")
Quencher:RegisterEvent("PLAYER_REGEN_ENABLED")
Quencher:RegisterEvent("UPDATE_INSTANCE_INFO")
Quencher:RegisterEvent("CHAT_MSG_RAID")
Quencher:RegisterEvent("CHAT_MSG_RAID_LEADER")
Quencher:RegisterEvent("CHAT_MSG_RAID_WARNING")
Quencher:SetScript("OnEvent", function()
  local h = Quencher[event]
  if h then h(arg1, arg2, arg3, arg4, arg5) end
end)

------------------------------------------------------------------
-- Slash commands: /quencher  (alias /qn)
------------------------------------------------------------------
SLASH_QUENCHER1 = "/quencher"
SLASH_QUENCHER2 = "/qn"
SlashCmdList["QUENCHER"] = function(msg)
  msg = string.lower(msg or "")
  local _, _, cmd, arg = string.find(msg, "^(%S*)%s*(.-)$")
  if cmd == "" or cmd == "status" then PrintProgress(nil)
  elseif cmd == "say" then PrintProgress(UnitInRaid("player") and "RAID" or "PARTY")
  elseif cmd == "history" then
    local rows = dbQuery("SELECT raid_id, count, updated FROM raid ORDER BY updated DESC LIMIT 10")
    if table.getn(rows) == 0 then out("No stored raids (or SQL unavailable).") end
    for i = 1, table.getn(rows) do
      out(format("raid %s: %s/%d (updated %s)", rows[i].raid_id, rows[i].count, MAX_DOUSES, date("%Y-%m-%d %H:%M", tonumber(rows[i].updated) or 0)))
    end
  elseif cmd == "retention" then
    local n = tonumber(arg)
    if n and n > 0 then QuencherDB.retention_days = n; out("retention set to "..n.." days") else out("retention: "..QuencherDB.retention_days.." days") end
  elseif cmd == "purge" then Purge(); out("old raids purged")
  elseif cmd == "debug" then DEBUG_MODE = not DEBUG_MODE; out("debug "..(DEBUG_MODE and "on" or "off"))
  else out("/quencher [status] | say | history | retention <days> | purge | debug   (raid chat: !douse)") end
end
