local json = require("json")
local maf = require("maf")
local socket = require("socket")
local http = require("socket.http")

local rootdir = lfs.currentdir():gsub("\\\\","\\") .. "\\Modules\\"
local rotorbrake = 66587
local remote_port = remote_port
local pilot = pilot
local human = human or not pilot or true
local noPauses = noPauses or false
local logging = true

-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local logname = rootdir .. "Lua_FSL_lib\\FSL.log"
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
      local speed = plusminus ((5.54785 + (-218.97685 / (1 + (dist / (3.62192 * 10^-19))^0.0786721))),0.1)
      log("Speed: " .. math.floor(speed * 1000) .. " mm/s")
      return plusminus(speed)
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

   initPos = function(self,control)
      local pos = control.pos
      pos = maf.vector(tonumber(pos.x), tonumber(pos.y), tonumber(pos.z))
      local ref = {
         --0,0,0 is at the bottom left corner of the pedestal's top side
         OVHD = {maf.vector(39,730,1070), 2.75762}, --bottom left corner (the one that is part of the bottom edge)
         --MIP = {maf.vector(), 0},
         GSLD = {maf.vector(-424, 663, 527), 1.32645} --bottom left corner of the panel with the chrono button
      }
      for section,refpos in pairs(ref) do
         if control.var:find(section) then
            local r = maf.rotation.fromAngleAxis(refpos[2], 1, 0, 0)
            pos = pos:rotate(r) + refpos[1]
         end
      end
      return pos
   end,

   new = function(self,control)
      control.pos = self:initPos(control)
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
      if (button and not self.posn) or (switch and self.posn) then
         log("Position of control " .. self.var:gsub("VC_", "") .. ": x = " .. math.floor(self.pos.x) .. ", y = " .. math.floor(self.pos.y) .. ", z = " .. math.floor(self.pos.z), 1)
         if human and not noPauses then
            local reachtime = hand:moveto(self.pos) 
            log("Control reached in " .. math.floor(reachtime) .. " ms")
         end
      end
      if button and not self.posn then
         self:press()
      elseif switch and self.posn then
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
      if human and not noPauses then
         ipc.sleep(t)
         log("Interaction with the control took " .. t .. " ms")
      end
   end,

   set = function(self,targetPos)
      targetPos = self.posn[targetPos:upper()]
      if not targetPos then return end
      local currPos = self:getVar()
      if currPos ~= targetPos then
         while true do
            currPos = self:getVar()
            if currPos < targetPos then
               if self.tgl then ipc.control(rotorbrake, self.tgl)
               else ipc.control(rotorbrake, self.inc) end
            elseif currPos > targetPos then
               if self.tgl then ipc.control(rotorbrake, self.tgl)
               else ipc.control(rotorbrake, self.dec) end
            else break end
            local t = plusminus(self.time or 300)
            if human and not noPauses then
               log("Interaction with the control took " .. t .. " ms")
               ipc.sleep(t) 
            end
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

   isDown = function(self) if not self.posn then return ipc.readLvar(self.var) == 10 end end

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
      local setting = tostring(self.atsuLog:takeoffFlaps() or self:getTakeoffFlapsFromMcdu())
      self.PED_FLAP_LEVER(setting)
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
      return tonumber(self.MCDU.getDisplay(side,162,162))
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

   },

}

FSL.trimwheel = {

   inc = 78375,
   dec = 78376,
   pos = {y = 500, z = 70},
   var = "VC_PED_trim_wheel_ind",

   getInd = function(self)
      ipc.sleep(5)
      local CG_ind = ipc.readLvar(self.var)
      if CG_ind <= 1800 and CG_ind > 460 then
         CG_ind = CG_ind * 0.045 - 52.9
      else
         CG_ind = CG_ind * 0.104 + 28.54
      end
      return CG_ind
   end,
   
   set = function(self,CG,step)
      local CG_man
      if CG then CG_man = true else CG = FSL.atsuLog:MACTOW() end
      if not CG then return end
      if not step then
         if not CG_man and prob(0.1) then log("Looking for the loadsheet") ipc.sleep(plusminus(10000,0.5)) end
         log("Setting the trim. MACTOW: " .. CG, 1)
         log("Position of the trimwheel: x = " .. math.floor(self.pos.x) .. ", y = " .. math.floor(self.pos.y) .. ", z = " .. math.floor(self.pos.z))
         local reachtime = hand:moveto(self.pos) 
         log("Trim wheel reached in " .. math.floor(reachtime) .. " ms")
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
            ipc.control(rotorbrake,self.inc)
            ipc.sleep(time - 5)
         elseif CG < CG_ind then
            if dist > 3.1 then self:set(CG_ind - 3,1) ipc.sleep(plusminus(350,0.2)) end
            ipc.control(rotorbrake,self.dec)
            ipc.sleep(time - 5)
         end
         local trimIsSet = math.abs(CG - CG_ind) <= 0.2
         if step then trimIsSet = math.abs(CG - CG_ind) <= 0.5 end
      until trimIsSet
      return CG
   end

}

if pilot == 1 then FSL.trimwheel.pos.x = 90 
elseif pilot == 2 then FSL.trimwheel.pos.x = 300 end

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
      local index = line:find("\\FSLabs\\SimObjects")
      if index then
         local type
         if ipc.readLvar("AIRCRAFT_A319") == 1 then type = "A319"
         elseif ipc.readLvar("AIRCRAFT_A320") == 1 then type = "A320"
         elseif ipc.readLvar("AIRCRAFT_A321") == 1 then type = "A321" end
         path = line:sub(1, index) .. "FSLabs\\" .. type .. "\\Data\\ATSU\\ATSU.log"
         --path = line:sub(1, index) .. "FSLabs\\" .. type .. "\\Data\\ATSU\\test.log"
         FSL.atsuLog.path = path:sub(path:find("%u"), #path)
         break
      end
   end
   io.close(file)
end

-- Main ---------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local rawControls = rootdir .. "Lua_FSL_lib\\FSL.json"
io.input(rawControls)
rawControls = json.parse(io.read())

for varname,control in pairs(rawControls) do
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
   local side
   for pattern, replace in pairs(replace.CPT) do
      if varname:find(pattern) then
         side = true
         if pattern == "_CP" and varname:find("_CPT") then pattern = "_CPT" end
         controlName = varname:gsub(pattern,replace)
         FSL.CPT[controlName] = Control:new(control)
         if pilot == 1 then FSL[controlName] = FSL.CPT[controlName]
         elseif pilot == 2 then FSL.PF[controlName] = FSL.CPT[controlName] end
      end
   end
   for pattern, replace in pairs(replace.FO) do
      if varname:find(pattern) then
         side = true
         controlName = varname:gsub(pattern,replace)
         FSL.FO[controlName] = Control:new(control)
         if pilot == 2 then FSL[controlName] = FSL.FO[controlName]
         elseif pilot == 1 then FSL.PF[controlName] = FSL.FO[controlName] end
      end
   end
   if not side then FSL[varname] = Control:new(control) end
end

return FSL