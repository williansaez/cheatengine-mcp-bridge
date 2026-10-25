-- TaskBarHero: read inventory / hero stats / equip, all through the CE bridge (evaluate_lua).
-- Requires: LaunchMonoDataCollector() once, and the mcp_req main-thread hook (see memory notes).
-- Usage inside evaluate_lua:  dofile([[<this file>]]); return TBH.report()
TBH = TBH or {}

local function clean(s) return (tostring(s):gsub("[^%w_`.<>$%[%],: ]", "?")) end
local function str(o)
  if not o or o < 0x10000 then return "?" end
  local len = readInteger(o + 0x10); if not len or len < 0 or len > 200 then return "?" end
  local t = {}
  for i = 0, len-1 do local c = readSmallInteger(o + 0x14 + i*2); t[#t+1] = (c and c >= 32 and c < 128) and string.char(c) or "?" end
  return table.concat(t)
end

-- resolve method addresses by class/name via the IL2CPP dissector
function TBH.method(cls, name)
  local k = mono_findClass("", cls)
  for _, m in ipairs(mono_class_enumMethods(k) or {}) do
    if clean(m.name) == name then return mono_compile_method(m.method) end
  end
end

-- main-thread call through the mcp_req hook
function TBH.callMain(func, this, slot, id)
  local req = getAddress("mcp_req")
  writeQword(req + 8, this); writeInteger(req + 0x10, slot); writeQword(req + 0x18, id); writeQword(req + 0x20, func); writeQword(req + 0x28, 0)
  writeQword(req, 1)
  local t0 = os.clock(); local state = 1
  while os.clock() - t0 < 3 do state = readQword(req); if state == 3 then break end; sleep(5) end
  return state == 3, readQword(req + 0x28)
end

-- heroes: Pstat code pattern -> klass vo -> statics -> dict +0x28 (slot -> xs)
function TBH.heroes()
  local GA = getAddress("GameAssembly.dll")
  local res = AOBScan("48 8B 05 ?? ?? ?? ?? 83 B8 E4 00 00 00 00 75 ?? 48 8B C8 E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 8B 80 B8 00 00 00 48 8B 48 20 48 85 C9 74 ?? 48 8B 15 ?? ?? ?? ?? E8", "+X-C-W", 0, GA, GA + getModuleSize("GameAssembly.dll"))
  local m = tonumber(res[0], 16); res.destroy()
  local Pstat = m + 7 + readInteger(m + 3)
  local statics = readPointer(readPointer(Pstat) + 0xB8)
  local pd = readPointer(statics + 0x28); local pe = readPointer(pd + 0x18); local pcap = readInteger(pe + 0x18)
  local out = {}
  for i = 0, pcap - 1 do
    local e = pe + 0x20 + i*24
    local hash = readInteger(e); local slot = readInteger(e + 8); local xs = readPointer(e + 16)
    if hash and hash >= 0 and xs and xs > 0x10000 then
      out[slot] = { xs = xs, heroId = readInteger(readPointer(xs + 0x30) + 0x30) }
    end
  end
  return out
end

function TBH.stats(xs)
  local d = readPointer(readPointer(xs + 0x10) + 0x20); local en = readPointer(d + 0x18)
  local v = function(id) return readFloat(en + 0x20 + id*16 + 12) end
  return { dano = v(1), velatq = v(2), crit = v(3), pv = v(5), def = v(6) }
end

-- all owned items from vu.bipc (Dictionary<ulong, vs>) via vu.jzm is per-id; walk the dict directly:
function TBH.items()
  local k = mono_findClass("", "vu")
  local dom = mono_enumDomains()[1]
  -- static block via any instance method is awkward; fall back to walking from a known item through the dict entries array:
  -- caller passes nothing; we locate the Entry[] by scanning for the ItemInfoData string pointer is slow, so prefer TBH.item(id).
  return nil
end

function TBH.item(id)
  local ok, p = TBH.callMain(TBH.method("vu", "jzm"), id, 0, 0)
  if not ok or not p or p == 0 then return nil end
  local info = readPointer(p + 0x10)
  return { obj = p, key = readInteger(info + 0x30), id = id, name = str(readPointer(info + 0x78)),
           slot = readInteger(info + 0x40) - 1, gearType = readInteger(info + 0x44), classType = readInteger(p + 0x30) }
end

function TBH.equipped(xs)
  local fxz = TBH.method("xs", "fxz")
  local t = {}
  for s = 0, 11 do local ok, id = TBH.callMain(fxz, xs, s, 0); if ok and id and id ~= 0 then t[s] = id end end
  return t
end

function TBH.equip(xs, id)
  local it = TBH.item(id); if not it then return false, "no item" end
  local ok, r = TBH.callMain(TBH.method("xs", "ldp"), xs, it.slot, id)
  return ok and ((r or 0) & 0xFF) == 1, it.name
end

function TBH.report()
  local out = {}
  for slot, h in pairs(TBH.heroes()) do
    local s = TBH.stats(h.xs)
    local eq = {}
    for k, id in pairs(TBH.equipped(h.xs)) do local it = TBH.item(id); eq[#eq+1] = string.format("s%d=%d(%s)", k, id, it and it.name or "?") end
    out[#out+1] = string.format("slot%d hero%d Dano=%.1f VelAtq=%.2f PV=%.0f Def=%.1f | %s", slot, h.heroId, s.dano, s.velatq, s.pv, s.def, table.concat(eq, " "))
  end
  return table.concat(out, "\n")
end
return TBH
