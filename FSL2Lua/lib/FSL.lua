local json = require("json")
local maf = require("maf")
local socket = require("socket")
local http = require("socket.http")

local rootdir = lfs.currentdir():gsub("\\\\","\\") .. "\\Modules\\"
local rotorbrake = 66587
local remote_port = remote_port
local pilot = FSL2Lua_pilot or pilot
local human = FSL2Lua_do_sequences or human or false
if not pilot then human = false end
local logging = FSL2Lua_log == 1

local ac_type
if ipc.readLvar("AIRCRAFT_A319") == 1 then ac_type = "A319"
elseif ipc.readLvar("AIRCRAFT_A320") == 1 then ac_type = "A320"
elseif ipc.readLvar("AIRCRAFT_A321") == 1 then ac_type = "A321" end

-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local logname = rootdir .. "FSL2Lua\\FSL.log"
io.open(logname,"w"):close()

local function log(str, drawline, notimestamp)
   if not logging then return end
   local file = io.open(logname,"a")
   io.input(file)
   io.output(file)
   local temp = os.date("*t", os.time())
   if temp.hour < 10 then
      temp.hour = "0" .. temp.hour
   end
   if temp.min < 10 then
      temp.min = "0" .. temp.min
   end
   if temp.sec < 10 then
      temp.sec = "0" .. temp.sec
   end
   local timestamp = "[" .. temp.hour .. ":" .. temp.min .. ":" .. temp.sec .. "] - "
   if notimestamp == 1 then timestamp = "" end
   if drawline == 1 then
      io.write("-------------------------------------------------------------------------------------------\n")
   end
   io.write(timestamp .. str .. "\n")
   io.close(file)
end

-- Human stuff --------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

math.randomseed(os.time())

function prob(prob) return math.random() <= prob end

function plusminus(val, percent)
   percent = percent or 0.2
   return val * math.random(100 - percent * 100, 100 + percent * 100) / 100
end

function think(dist)
   local time = plusminus(300)
   if dist > 50 then 
      time = time + plusminus(200)
      if prob(0.2) then time = time + plusminus(500) end
      if prob(0.05) then time = time + plusminus(1000) end
   end
   log("Thinking for " .. time .. " ms. Hmmm...")
   ipc.sleep(time)
end

hand = {

   speed = function(dist)
      log("Distance: " .. math.floor(dist) .. " mm")
      if dist < 80 then dist = 80 end
      local speed = 5.54785 + (-218.97685 / (1 + (dist / (3.62192 * 10^-19))^0.0786721))
      speed = plusminus(speed,0.1)
      log("Speed: " .. math.floor(speed * 1000) .. " mm/s")
      return speed
   end,

   moveto = function(self,newpos)
      local dist = (newpos - self.pos):length()
      if self.pos ~= self.home and newpos ~= self.home then think(dist) end
      local time = dist / self.speed(dist)
      ipc.sleep(time)
      self.pos = newpos
      return time
   end,

   rest = function(self) self:moveto(self.home) end
}

if pilot == 1 then hand.home = maf.vector(-70,420,70)
elseif pilot == 2 then hand.home = maf.vector(590,420,70) end

hand.pos = hand.home

-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local Control = {

   new = function(self,control)
      if control.var:find("Guard") then control.guard = true end
      setmetatable(control,self)
      if control.posn then
         local temp = control.posn
         control.posn = {}
         for k,v in pairs(temp) do
            control.posn[k:lower()] = v
            control.posn[k:upper()] = v
         end
      end
      return control
   end,

   __call = function(self,targetPos)
      local button = not targetPos
      local switch = not button
      local knob = self.range
      if (button and not self.posn) or (switch and self.posn) then
         log("Position of control " .. self.var:gsub("VC_", "") .. ": x = " .. math.floor(self.pos.x) .. ", y = " .. math.floor(self.pos.y) .. ", z = " .. math.floor(self.pos.z), 1)
         if human then
            local reachtime = hand:moveto(self.pos) 
            log("Control reached in " .. math.floor(reachtime) .. " ms")
         end
      end
      if button and not self.posn then
         self:press()
      elseif (switch and self.posn) or knob then
         self:set(targetPos)
      end
   end,

   press = function(self)
      if self.inc and self.dec then
         ipc.control(rotorbrake, self.inc)
         ipc.sleep(50)
         ipc.control(rotorbrake, self.dec)
      elseif self.tgl then
         ipc.control(rotorbrake, self.tgl)
      end
      local t = plusminus(self.time or 300) - 50
      if human then
         ipc.sleep(t)
         log("Interaction with the control took " .. t .. " ms")
      end
   end,

   set = function(self,targetPos)
      if not targetPos then return end
      local sleepTime = 5
      if self.range and type(targetPos) == "number" then
         targetPos = self.range / 100 * targetPos
      elseif type(targetPos) == "string" then
         if human then sleepTime = self.time or 100 end
         targetPos = self.posn[targetPos:upper()]
      end
      local currPos = self:getVar()
      if currPos ~= targetPos then
         while true do
            currPos = self:getVar()
            if currPos < targetPos then
               if self.control then ipc.control(self.control.inc)
               elseif self.tgl then ipc.control(rotorbrake, self.tgl)
               else ipc.control(rotorbrake, self.inc) end
            elseif currPos > targetPos then
               if self.control then ipc.control(self.control.dec)
               elseif self.tgl then ipc.control(rotorbrake, self.tgl)
               else ipc.control(rotorbrake, self.dec) end
            else
               if self.hidepointer then
                  local x,y = mouse.getpos()
                  mouse.move(x+1,y+1)
                  mouse.move(x,y)
                  ipc.sleep(10)
                  ipc.control(1139)
               end
               break
            end
            local t = plusminus(sleepTime)
            ipc.sleep(t) 
            if human then log("Interaction with the control took " .. t .. " ms") end
         end
      end
   end,

   getPosn = function(self)
      if self.posn then
         local val = ipc.readLvar(self.var)
         for k,v in pairs(self.posn) do
            if v == val then return k:upper() end
         end
      end
   end,

   isLit = function(self)
      if type(self.Lt) == "string" then return ipc.readLvar(self.Lt) == 1
      else return ipc.readLvar(self.Lt.Brt) == 1 or ipc.readLvar(self.Lt.Dim) == 1 end
   end,

   getVar = function(self) return ipc.readLvar(self.var) end,

   isDown = function(self) if not self.posn then return ipc.readLvar(self.var) == 10 end end,

   open = function(self) if self.guard then ipc.control(rotorbrake,self.inc) end end,

   close = function(self) if self.guard then ipc.control(rotorbrake,self.dec) end end,

   push = function(self) if self.pushctrl then ipc.control(rotorbrake,self.pushctrl) end end,

   pull = function(self) if self.pullctrl then ipc.control(rotorbrake,self.pullctrl) end end

}

Control.__index = Control

local FSL = {

   CPT = {}, FO = {}, PF = {},

   getThrustLeversPos = function(self,TL)
      local TL_posns = {
         REV_MAX = 199,
         REV_IDLE = 129,
         IDLE = 0,
         CLB = 25,
         FLX = 35,
         TOGA = 45
      }
      local pos
      if TL == 1 then pos = ipc.readLvar("VC_PED_TL_1") 
      elseif TL == 2 then pos = ipc.readLvar("VC_PED_TL_2")
      end
      for k,v in pairs(TL_posns) do
         if (pos and math.abs(pos - v) < 4) or (not pos and math.abs(ipc.readLvar("VC_PED_TL_1")  - v) < 4 and math.abs(ipc.readLvar("VC_PED_TL_2")  - v) < 4) then
            return k
         end
      end
   end,

   setTakeoffFlaps = function(self)
      local setting = self.atsuLog:takeoffFlaps() or self:getTakeoffFlapsFromMcdu()
      if setting then self.PED_FLAP_LEVER(tostring(setting)) end
      return setting
   end,

   startTheApu = function(self)
      if not self.OVHD_APU_Master_Button:isDown() then self.OVHD_APU_Master_Button() end
      ipc.sleep(plusminus(2000,0.3))
      self.OVHD_APU_Start_Button()
   end,

   getTakeoffFlapsFromMcdu = function(self,side)
      side = side or pilot
      if side == 1 then _side = "CPT" elseif side == 2 then _side = "FO" end
      self[_side].PED_MCDU_KEY_PERF()
      ipc.sleep(500)
      local setting = self.MCDU.getDisplay(side,162,162)
      self[_side].PED_MCDU_KEY_FPLN()
      return tonumber(setting)
   end,
   
   bird = function()
      local port = remote_port or "8080"
      local FCU = http.request("http://localhost:" .. port .. "/FCU/Display")
      return FCU:find("HDG_VS_SEL\":false")
   end,

   MCDU = {

      getDisplay = function(side,startpos,endpos)
         local port = remote_port or "8080"
         local displaystr = http.request("http://localhost:" .. port .. "/MCDU/Display/3CA" .. side)
         displaystr = displaystr:sub(displaystr:find("%[%[") + 1, displaystr:find("%]%]"))
         local display = {}
         for unit in displaystr:gmatch("%[(.-)%]") do
            if unit:find(",") then
               unit = unit:sub(1, unit:find(",") - 1)
            end
            if unit == "" then unit = " "
            else unit = string.char(tonumber(unit)) end
            display[#display + 1] = unit
         end
         if startpos then display = table.concat(display,nil,startpos,endpos or #display) end
         return display -- either - if no startpos is specified - the whole display as an array, or a string from startpos to either endpos or the end of the display if no endpos is specified
      end

   }

}

FSL.trimwheel = {

   control = {inc = 65607, dec = 65615},
   pos = {y = 500, z = 70},
   var = "VC_PED_trim_wheel_ind",

   getInd = function(self)
      ipc.sleep(5)
      local CG_ind = ipc.readLvar(self.var)
      if ac_type == "A320" then
         if CG_ind <= 1800 and CG_ind > 460 then
            CG_ind = CG_ind * 0.0482226 - 58.19543
         else
            CG_ind = CG_ind * 0.1086252 + 28.50924
         end
      elseif ac_type == "A319" then
         if CG_ind <= 1800 and CG_ind > 460 then
            CG_ind = CG_ind * 0.04687107 - 53.76288
         else
            CG_ind = CG_ind * 0.09844237 + 30.46262
         end
      end
      return CG_ind
   end,
   
   set = function(self,CG,step)
      local CG_man
      if CG then CG_man = true else CG = FSL.atsuLog:MACTOW() end
      if not CG then return end
      if not step then
         if not CG_man and prob(0.1) then log("Looking for the loadsheet") ipc.sleep(plusminus(10000,0.5)) end
         log("Setting the trim. CG: " .. CG, 1)
         if human then
            log("Position of the trimwheel: x = " .. math.floor(self.pos.x) .. ", y = " .. math.floor(self.pos.y) .. ", z = " .. math.floor(self.pos.z))
            local reachtime = hand:moveto(self.pos) 
            log("Trim wheel reached in " .. math.floor(reachtime) .. " ms")
         end
      end
      repeat
         local CG_ind = self:getInd()
         local dist = math.abs(CG_ind - CG)
         local speed = plusminus(0.2) -- the reciprocal of the speed, actually
         if step then speed = plusminus(0.07) end
         local time = math.ceil(1000 / (dist / speed))
         if time < 40 then time = 40 end
         if time > 1000 then time = 1000 end
         if step and time > 70 then time = 70 end
         if CG > CG_ind then
            if dist > 3.1 then self:set(CG_ind + 3,1) ipc.sleep(plusminus(350,0.2)) end
            ipc.control(self.control.inc)
            ipc.sleep(time - 5)
         elseif CG < CG_ind then
            if dist > 3.1 then self:set(CG_ind - 3,1) ipc.sleep(plusminus(350,0.2)) end
            ipc.control(self.control.dec)
            ipc.sleep(time - 5)
         end
         local trimIsSet = math.abs(CG - CG_ind) <= 0.2
         if step then trimIsSet = math.abs(CG - CG_ind) <= 0.5 end
      until trimIsSet
      return CG
   end

}

do
   local pos = FSL.trimwheel.pos
   if pilot == 1 then pos.x = 90 
   elseif pilot == 2 then pos.x = 300 end
   FSL.trimwheel.pos = maf.vector(pos.x, pos.y, pos.z)
end

FSL.atsuLog = {

   get = function(self)
      local path = self.path
      if not path then return end
      local file = io.open(path)
      if not file then return end
      io.input(file)
      local log = {}
      repeat
         local line = io.read()
         log[#log + 1] = line
      until not line
      io.close(file)
      return log
   end,

   MACTOW = function(self)
      local _log = log
      local log = self:get()
      if not log then return end
      for i = #log,1,-1 do
         local line = log[i]
         local _, pos = line:find("MACTOW")
         if pos then
            line = line:sub(pos,#line)
            local CG = tonumber(line:sub(line:find("(%d*%.?%d+)")))
            if CG > 0 then 
               _log("The MACTOW from the latest ATSU loadsheet is " .. CG, 1)
               return CG 
            end
         end
      end
   end,

   takeoffPacks = function(self)
      local _log = log
      local log = self:get()
      if not log then return end
      for i = #log,1,-1 do
         local line = log[i]
         if line:find("PACKS") then
            if line:find("OFF") then
               _log("The packs are OFF in the latest ATSU performance request", 1)
               return 0
            elseif line:find("ON") then
               _log("The packs are ON in the latest ATSU performance request", 1)
               return 1 
            end
         end
      end
   end,

   takeoffFlaps = function(self)
      local log = self:get()
      if not log then return end
      for i = #log,1,-1 do
         local line = log[i]
         if line:find("FLAPS") then return log[i+1]:sub(#log[i+1],#log[i+1]) end
      end
   end

}

do
   local file = io.open(rootdir .. "FSUIPC5.log")
   if not file then return end
   io.input(file)
   local path
   while true do
      local line = io.read()
      if not line then break end
      local index = line:find("\\FSLabs\\SimObjects")
      if index then
         path = line:sub(1, index) .. "FSLabs\\" .. ac_type .. "\\Data\\ATSU\\ATSU.log"
         --path = line:sub(1, index) .. "FSLabs\\" .. ac_type .. "\\Data\\ATSU\\test.log"
         FSL.atsuLog.path = path:sub(path:find("%u"), #path)
         break
      end
   end
   io.close(file)
end

-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

keyBindCount = 0

function keyBind(keycode,func,cond,shifts,downup)
   cond = cond or function() return true end
   keyBindCount = keyBindCount + 1
   local funcName = "keyBind" .. keyBindCount
   _G[funcName] = function() if cond() then func() end end
   event.key(keycode,shifts,1 or downup,funcName)
end

-- Main ---------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local rawControls = rootdir .. "FSL2Lua\\lib\\FSL.json"
io.input(rawControls)
rawControls = json.parse(io.read())

function initPos(varname,control)
   local pos = control.pos
   local mirror = {
      MCDU_R = "MCDU_L",
      COMM_2 = "COMM_1",
      RADIO_2 = "RADIO_1"
   }
   for k,v in pairs(mirror) do
      if varname:find(k) then
         pos = rawControls[varname:gsub(k,v)].pos
         if pos.x and pos.x ~= "" then
            pos.x = tonumber(pos.x) + 370
         end
      end
   end
   pos = maf.vector(tonumber(pos.x), tonumber(pos.y), tonumber(pos.z))
   local ref = {
      --0,0,0 is at the bottom left corner of the pedestal's top side
      OVHD = {maf.vector(39, 730, 1070), 2.75762}, -- bottom left corner (the one that is part of the bottom edge)
      MIP = {maf.vector(0, 792, 59), 1.32645}, -- left end of the edge that meets the pedestal
      GSLD = {maf.vector(-424, 663, 527), 1.32645} -- bottom left corner of the panel with the autoland button
   }
   for section,refpos in pairs(ref) do
      if control.var:find(section) then
         local r = maf.rotation.fromAngleAxis(refpos[2], 1, 0, 0)
         pos = pos:rotate(r) + refpos[1]
      end
   end
   return pos
end

for varname,control in pairs(rawControls) do
   control.pos = initPos(varname,control)
   if varname:find("Knob") or varname:find("KNOB") then control.hidepointer = true end
   local replace = {
      CPT = {
         MCDU_L = "MCDU",
         COMM_1 = "COMM",
         RADIO_1 = "RADIO",
         _CP = ""
      },
      FO = {
         MCDU_R = "MCDU",
         COMM_2 = "COMM",
         RADIO_2 = "RADIO",
         _FO = ""
      }
   }
   local controlTbl, side
   for pattern, replace in pairs(replace.CPT) do
      if varname:find(pattern) then
         if pattern == "_CP" and varname:find("_CPT") then pattern = "_CPT" end
         controlName = varname:gsub(pattern,replace)
         FSL.CPT[controlName] = Control:new(control)
         controlTbl = FSL.CPT[controlName]
         controlTbl.name = controlName
         controlTbl.side = "CPT"
         if pilot == 1 then FSL[controlName] = FSL.CPT[controlName]
         elseif pilot == 2 then FSL.PF[controlName] = FSL.CPT[controlName] end
      end
   end
   for pattern, replace in pairs(replace.FO) do
      if varname:find(pattern) then
         controlName = varname:gsub(pattern,replace)
         FSL.FO[controlName] = Control:new(control)
         controlTbl = FSL.FO[controlName]
         controlTbl.name = controlName
         controlTbl.side = "FO"
         if pilot == 2 then FSL[controlName] = FSL.FO[controlName]
         elseif pilot == 1 then FSL.PF[controlName] = FSL.FO[controlName] end
      end
   end
   if not controlTbl then
      FSL[varname] = Control:new(control)
      controlTbl = FSL[varname]
      controlTbl.name = varname
   end
   if controlTbl.posn then
      for pos in pairs(controlTbl.posn) do
         if controlTbl.side then
            FSL[controlTbl.side][controlTbl.name .. "_" .. pos:upper()] = function() controlTbl:set(pos) end
         else
            FSL[controlTbl.name .. "_" .. pos:upper()] = function() controlTbl:set(pos) end
         end
      end
   end
end

return FSL