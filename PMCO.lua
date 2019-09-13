-- "PMCO - Pilot Monitoring Callouts" FREEWARE LUA script
-- Version:
-- by Nils Unger, Peter Pukhnoy

-- ##################################################################
-- ############ EDIT USER OPTIONS HERE ##############################
-- ##################################################################

-- Callouts:

play_V1 = 1 -- play V1 sound? 0 = no, 1 = yes
V1_timing = 0 --V1 will be announced at the speed of V1 - V1_timing. If you want V1 to be announced slightly before V1 is reached on the PFD, enter the number of kts.
PM = 2 -- Pilot Monitoring: 1 = Captain, 2 = First Officer
display_startup_message = 1 -- show startup message? 0 = no, 1 = yes
sound_device = 0 -- zero is default (only change this when no sound is played)
volume = 65 -- volume of all callouts (zero does NOT mean silenced, just rather quiet)
PM_announces_flightcontrol_check = 1 -- PM calls out 'full left', 'full right' etc.
PM_announces_brake_check = 1 -- PM calls out 'brake pressure zero' after the brake check. The trigger is the first application of the brakes after you start moving

-- Actions:

enable_actions = 0 -- allow the PM to perform the procedures that are listed below
SOP = "default"

-- Enable or disable individual procedures in the 'default' SOP and change their related options:

after_start = 1 -- triggered when at least one engine is running and the engine mode selector is in the 'NORM' position
during_taxi = 1 -- the PM will press the AUTO BRK and TO CONFIG buttons after you've done the brake and flight controls checks
lineup = 1 -- triggered by cycling the seat belts sign switch twice within 2 seconds
after_takeoff = 1 -- triggered by moving the thrust levers into the 'CLB' detent
after_landing = 1 -- triggered when the ground speed is less than 30 kts and you have disarmed the spoilers

packs_on_takeoff = 0 -- 0 = takeoff with packs OFF. This option will be ignored if a performance request is found in the ATSU log
pack2_off_after_landing = 0

-- ##################################################################
-- ############### END OF USER OPTIONS ##############################
-- ##################################################################

-- Don't edit below this line unless you're some kind of hacker or something ------------
-----------------------------------------------------------------------------------------

pilot = PM
noPauses = true
local FSL = require("FSL")

local sound_path = "..\\Modules\\PMCO_Sounds\\" -- path to the callout sounds
local loopCycleCritical = 100 -- cycle time for critical loops
local loopCycleResting = 1000 -- cycle time for resting loops
local PFD_delay = 650 --milliseconds
local ECAM_delay = 300
local TL_takeoffThreshold = 26
local TL_reverseThreshold = 100
local reverserDoorThreshold = 90
local spoilerThreshold = 200
local previousCallout

-- Logging ------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local logname = "Pilot Monitoring Callouts.log"
io.open(logname,"w"):close()

function log(str)
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
   local prefix = "PMCO: "
   ipc.log(prefix .. timestamp .. str)
   io.write(timestamp .. str .. "\n")
   io.close(file)
end

-- Callouts -----------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

function restingLoop() ipc.sleep(loopCycleResting) end
function criticalLoop() ipc.sleep(loopCycleCritical) end
function onGround() return ipc.readUB(0x0366) == 1 end
function groundSpeed() return ipc.readUD(0x02B4) / 65536 * 3600 / 1852 end
function timePassedSince(ref) return ipc.elapsedtime() - ref end

function thrustLeversSetForTakeoff()
   local TL1, TL2 = ipc.readLvar("VC_PED_TL_1"), ipc.readLvar("VC_PED_TL_2")
   return TL1 < TL_reverseThreshold and TL1 >= TL_takeoffThreshold and TL2 < TL_reverseThreshold and TL2 >= TL_takeoffThreshold
end

function enginesRunning()
   local eng1_N1 = ipc.readUW(0x0898) * 100 / 16384
   local eng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   return eng1_N1 > 15 and eng2_N1 > 15
end

function thrustIsSet()
   local eng1_N1 = ipc.readUW(0x0898) * 100 / 16384
   local eng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   return eng1_N1 > 80 and eng2_N1 > 80
end

function announce(fileName)
   local reactionTime = 750
   if fileName == "spoilers" or fileName =="reverseGreen" or fileName == "decel" or fileName == "70knots" then
      ipc.sleep(ECAM_delay + reactionTime)
   elseif fileName == "100knots" or fileName == "v1" or fileName == "rotate" then
       ipc.sleep(PFD_delay) 
   end
   repeat ipc.sleep(50) until not sound.query(previousCallout)
   previousCallout = sound.play(fileName,sound_device,volume)
end

local callouts = {

   init = function(self)
      self.airborne = not onGround()
      self.cancelCountDownStart = nil
      self.landedAtTime = nil
      self.takeoffAbortedAtTime = nil
      self.brakesChecked = false
      self.flightControlsChecked = false
      ipc.set("flightControlsChecked", nil)
      ipc.set("brakesChecked", nil)
   end,

   __call = function(self) -- main logic

      if not self.falseTrigger then self:init() end

      repeat
         if not enginesRunning() then self.skipChecks = false end
         restingLoop()
      until enginesRunning()

      if onGround() and not self.skipChecks then
         local flightControlsCheck = coroutine.create(function() self:flightControlsCheck() end)
         local brakeCheck = coroutine.create(function() self:brakeCheck() end)
         repeat ipc.sleep(5)
         until not coroutine.resume(flightControlsCheck) and not coroutine.resume(brakeCheck)
      end

      if onGround() then 
         repeat 
            local takeoff = self:takeoff()
            local abortedTakeoff = not takeoff and self.takeoffAbortedAtTime
            self.falseTrigger = not takeoff and not abortedTakeoff
            if self.falseTrigger then return end
            restingLoop()
         until takeoff or abortedTakeoff or not enginesRunning()
      end

      if not enginesRunning() then return end

      while not onGround() do
         if not self.airborne then self.airborne = true end
         restingLoop()
      end

      if self.airborne then self.landedAtTime = ipc.elapsedtime() end

      self:rollout()

      self.skipChecks = true

   end,

   takeoffCancelled = function (self)
      local waitUntilCancel = 10000
      if not thrustLeversSetForTakeoff() then
         local aborted = thrustIsSet() and groundSpeed() > 10 and (FSL.getThrustLeversPos(1) == "IDLE" and FSL.getThrustLeversPos(2) == "IDLE") or (FSL.getThrustLeversPos(1) == "REV_IDLE" and FSL.getThrustLeversPos(2) == "REV_IDLE") or (FSL.getThrustLeversPos(1) == "REV_MAX" and FSL.getThrustLeversPos(2) == "REV_MAX")
         if aborted then
            self.takeoffAbortedAtTime = ipc.elapsedtime()
            return true 
         end
         if not self.cancelCountDownStart then
            self.cancelCountDownStart = ipc.elapsedtime()
         elseif ipc.elapsedtime() - self.cancelCountDownStart > waitUntilCancel then
            self.cancelCountDownStart = nil
            log("Cancelling the takeoff logic because the thrust levers were moved back for longer than " .. waitUntilCancel / 1000 .. " seconds")
            return true
         end
      elseif self.cancelCountDownStart then self.cancelCountDownStart = nil end
   end,

   takeoff = function(self)

      repeat restingLoop() until thrustLeversSetForTakeoff()
      ipc.sleep(5000)
      if not thrustLeversSetForTakeoff() then return false end

      FSL.PED_MCDU_KEY_PERF()
      ipc.sleep(500)
      local V1Select = tonumber(FSL.MCDU.getDisplay(PM,49,51))
      local VrSelect = tonumber(FSL.MCDU.getDisplay(PM,97,99))
      FSL.PED_MCDU_KEY_FPLN()
      if not V1Select then log("V1 hasn't been entered") end
      if not VrSelect then log("Vr hasn't been entered") end

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:thrustSet()

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:oneHundred()

      if play_V1 == 1 then
         repeat
            if self:takeoffCancelled() then return false end
            criticalLoop()
         until self:V1(V1Select)
      end

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:rotate(VrSelect)

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:positiveClimb()

      return true

   end,

   rollout = function(self)
      repeat criticalLoop() until self:spoilers()
      repeat criticalLoop() until self:reverseGreen()
      repeat criticalLoop() until self:decel()
      repeat criticalLoop() until self:seventy()
   end,

   thrustSet = function(self)
      local thrustSet, skipThis
      local ALT = ipc.readUD(0x31e4)/65536
      local IAS = ipc.readUW(0x02bc)/128
      if (ALT < 10.0) and thrustIsSet() then
         thrustSet = true
         ipc.sleep(800) -- wait for further spool up
         announce("thrustSet")
         log("thrust set")
      elseif (IAS > 80.0) then
         skipThis = true
         log("thrust set skipped (IAS > 80 kts)")
      end
      return thrustSet or skipThis
   end,

   oneHundred = function(self)
      local oneHundred
      local ALT = ipc.readUD(0x31e4)/65536
      local IAS = ipc.readUW(0x02bc)/128
      if (ALT < 10.0 and IAS >= 100.0) then
         oneHundred = true
         announce("100knots")
         log("reached 100 kts")
      end
      return oneHundred
   end,

   V1 = function(self,V1Select)
      local V1
      local ALT = ipc.readUD(0x31e4)/65536
      local IAS = ipc.readUW(0x02bc)/128
      if (ALT < 10.0 and IAS >= V1Select) then
         V1 = true
         announce("v1", 900)
         log("reached V1")
      end
      return V1
   end,

   rotate = function(self,VrSelect)
      local rotate
      local ALT = ipc.readUD(0x31e4)/65536
      local IAS = ipc.readUW(0x02bc)/128
      if (ALT < 10.0 and IAS >= VrSelect) then
         rotate = true
         announce("rotate")
         log("reached Vr")
      end
      return rotate
   end,

   positiveClimb = function(self)
      local positiveClimb, skipThis
      local ALT = ipc.readUD(0x31e4)/65536
      local vertSpeed = ipc.readSW(0x02c8)*60*3.28084/256
      if (ALT >= 10.0 and vertSpeed >= 500) then
         positiveClimb = true
         announce("positiveClimb")
         log("reached positive climb")
      elseif (ALT > 150.0) then -- skip criterium: 150m / 500ft
         skipThis = true
         log("positive climb skipped (ALT > 500ft)")
      end
      return positiveClimb or skipThis
   end,

   spoilers = function(self)
      local spoilers, skipThis
      local ALT = ipc.readUD(0x31e4)/65536
      local spoiler_L_Deployed = ipc.readLvar("FSLA320_spoiler_l_2") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_l_3") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_l_4") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_l_5") > spoilerThreshold
      local spoiler_R_Deployed = ipc.readLvar("FSLA320_spoiler_r_2") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_r_3") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_r_4") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_r_5") > spoilerThreshold
      local reverser_L = ipc.readLvar("FSLA320_reverser_left")
      local reverser_R = ipc.readLvar("FSLA320_reverser_right")

      if spoiler_L_Deployed and spoiler_L_Deployed then
         spoilers = true
         log("spoilers deployed")
         announce("spoilers")

      elseif groundSpeed() <= 100 then skipThis = true 
      elseif timePassedSince(self.landedAtTime or self.takeoffAbortedAtTime) > 2000 then 
         ipc.sleep(1000)
         if onGround() then
            skipThis = true 
         end
      end
      if skipThis then log("skipped spoilers deployed") end

      return spoilers or skipThis
   end,

   reverseGreen = function(self)
      local reverseGreen, skipThis
      local reverser_L = ipc.readLvar("FSLA320_reverser_left")
      local reverser_R = ipc.readLvar("FSLA320_reverser_right")
      if ((reverser_L >= reverserDoorThreshold) and (reverser_R >= reverserDoorThreshold)) then
         reverseGreen = true
         log("detected reverse green")
         announce("reverseGreen")
      elseif (groundSpeed() <= 90.0) then
         skipThis = true
         log("skipped reverse green")
      end
      return reverseGreen or skipThis
   end,

   decel = function(self)
      local decel, skipThis
      local accelLateral = ipc.readDBL(0x3070)
      if accelLateral < -4.0 then
         decel = true
         log("detected deceleration")
         announce("decel")
      elseif groundSpeed() <= 80.0 then -- skip criterium
         skipThis = true
         log("not enough deceleration -> skipped callout")
      end
      return decel or skipThis
   end,

   seventy = function(self)
      local seventy
      if groundSpeed() <= 70.0 then
         seventy = true
         announce("70knots")
         log("reached 70 kts")
      end
      return seventy
   end,

   brakeCheck = function(self)

      if PM_announces_brake_check == 0 then return end
      sound.path(sound_path)

      repeat

         if thrustLeversSetForTakeoff() then return end

         local leftBrakeApp = ipc.readUW(0x0BC4) * 100 / 16383
         local rightBrakeApp = ipc.readUW(0x0BC6) * 100 / 16383
         local leftPressure = ipc.readLvar("VC_MIP_BrkPress_L")
         local rightPressure = ipc.readLvar("VC_MIP_BrkPress_R")
         local pushback = ipc.readLvar("FSLA320_NWS_Pin") == 1
         local brakeAppThreshold = 1
         local brakesChecked

         if not pushback and groundSpeed() > 0.5 and leftBrakeApp > brakeAppThreshold and rightBrakeApp > brakeAppThreshold then
            ipc.sleep(2000)
            if leftBrakeApp > brakeAppThreshold and rightBrakeApp > brakeAppThreshold and leftPressure == 0 and rightPressure == 0 then
               announce("pressureZero")
               brakesChecked = true
            end
         end

         coroutine.yield()
         
      until brakesChecked

      ipc.set("brakesChecked",1)
      self.brakesChecked = true

   end
}

callouts.flightControlsCheck = {

   elevatorTolerance = 200,
   aileronTolerance = 300,
   spoilerTolerance = 100,
   rudderTolerance = 100,

   __call = function(self)

      if PM_announces_flightcontrol_check == 0 then return end

      local fullLeft, fullRight, fullLeftRud, fullRightRud, fullUp, fullDown, xNeutral, yNeutral, rudNeutral
      sound.path(sound_path)
      
      repeat

         if thrustLeversSetForTakeoff() then return end

         -- full left aileron
         if not fullLeft and not ((fullUp or fullDown) and not yNeutral) and self:fullLeft() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullLeft1")
            fullLeft = true
         end

         -- full right aileron
         if not fullRight and not ((fullUp or fullDown) and not yNeutral) and self:fullRight() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullRight1")
            fullRight = true
         end

         -- neutral after full left and full right aileron
         if fullLeft and fullRight and not xNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("neutral1")
            xNeutral = true
         end

         -- full up
         if not fullUp and not ((fullLeft or fullRight) and not xNeutral) and self:fullUp() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullUp")
            fullUp = true
         end

         -- full down
         if not fullDown and not ((fullLeft or fullRight) and not xNeutral) and self:fullDown() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullDown")
            fullDown = true
         end

         -- neutral after full up and full down
         if fullUp and fullDown and not yNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("neutral2")
            yNeutral = true
         end

         -- full left rudder
         if not fullLeftRud and xNeutral and yNeutral and self:fullLeftRud() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullLeft2")
            fullLeftRud = true
         end

         -- full right rudder
         if not fullRightRud and xNeutral and yNeutral and self:fullRightRud() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullRight2")
            fullRightRud = true
         end

         -- neutral after full left and full right rudder
         if fullLeftRud and fullRightRud and not rudNeutral and self:rudNeutral() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("neutral3")
            rudNeutral = true
         end

         if not fullLeft and not fullRight and not fullUp and not fullDown and not fullLeftRud and not fullRightRud then
            coroutine.yield()
         end

      until xNeutral and yNeutral and rudNeutral

      self.flightControlsChecked = true
      ipc.set("flightControlsChecked",1)
   end,

   fullLeft = function(self)
      local aileronLeft
      if ipc.readLvar("FSLA320_flap_l_1") == 0 then
         aileronLeft = ipc.readLvar("FSLA320_aileron_l") <= 1499 and 1499 - ipc.readLvar("FSLA320_aileron_l") < self.aileronTolerance
      elseif ipc.readLvar("FSLA320_flap_l_1") > 0 then
         aileronLeft = ipc.readLvar("FSLA320_aileron_l") <= 1199 and 1199 - ipc.readLvar("FSLA320_aileron_l") < self.aileronTolerance
      end
      return
      aileronLeft and
      1500 - ipc.readLvar("FSLA320_spoiler_l_2") < self.spoilerTolerance and
      1500 - ipc.readLvar("FSLA320_spoiler_l_3") < self.spoilerTolerance and
      1500 - ipc.readLvar("FSLA320_spoiler_l_4") < self.spoilerTolerance and
      1500 - ipc.readLvar("FSLA320_spoiler_l_5") < self.spoilerTolerance
   end,

   fullRight = function(self)
      local aileronRight
      if ipc.readLvar("FSLA320_flap_l_1") == 0 then
         aileronRight = 3000 - ipc.readLvar("FSLA320_aileron_r") < self.aileronTolerance
      elseif ipc.readLvar("FSLA320_flap_l_1") > 0 then
         aileronRight = 2700 - ipc.readLvar("FSLA320_aileron_r") < self.aileronTolerance
      end
      return
      aileronRight and
      1500 - ipc.readLvar("FSLA320_spoiler_r_2") < self.spoilerTolerance and
      1500 - ipc.readLvar("FSLA320_spoiler_r_3") < self.spoilerTolerance and
      1500 - ipc.readLvar("FSLA320_spoiler_r_4") < self.spoilerTolerance and
      1500 - ipc.readLvar("FSLA320_spoiler_r_5") < self.spoilerTolerance
   end,

   fullUp = function(self)
      return
      ipc.readLvar("FSLA320_elevator_l") <= 1499 and 1499 - ipc.readLvar("FSLA320_elevator_l") < self.elevatorTolerance and
      ipc.readLvar("FSLA320_elevator_r") <= 1499 and 1499 - ipc.readLvar("FSLA320_elevator_r") < self.elevatorTolerance
   end,

   fullDown = function(self)
      return
      3000 - ipc.readLvar("FSLA320_elevator_l") < self.elevatorTolerance and
      3000 - ipc.readLvar("FSLA320_elevator_r") < self.elevatorTolerance
   end,

   fullLeftRud = function(self)
      return ipc.readLvar("FSLA320_rudder") < 1500 and 1500 - ipc.readLvar("FSLA320_rudder") < self.rudderTolerance
   end,

   fullRightRud = function(self)
      return 3000 - ipc.readLvar("FSLA320_rudder") < self.rudderTolerance
   end,

   stickNeutral = function(self)
      local aileronsNeutral
      if ipc.readLvar("FSLA320_flap_l_1") == 0 then
         aileronsNeutral = (ipc.readLvar("FSLA320_aileron_l") < self.aileronTolerance or (ipc.readLvar("FSLA320_aileron_l") >= 1500 and ipc.readLvar("FSLA320_aileron_l") - 1500 < self.aileronTolerance)) and
                           (ipc.readLvar("FSLA320_aileron_r") < self.aileronTolerance or (ipc.readLvar("FSLA320_aileron_r") >= 1500 and ipc.readLvar("FSLA320_aileron_r") - 1500 < self.aileronTolerance))
      elseif ipc.readLvar("FSLA320_flap_l_1") > 0 then
         aileronsNeutral = math.abs(ipc.readLvar("FSLA320_aileron_l") - 1980) < self.aileronTolerance and math.abs(ipc.readLvar("FSLA320_aileron_r") - 480) < self.aileronTolerance
      end
      return
      aileronsNeutral and
      ipc.readLvar("FSLA320_spoiler_l_2") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_l_3") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_l_4") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_l_5") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_r_2") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_r_3") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_r_4") < self.spoilerTolerance and
      ipc.readLvar("FSLA320_spoiler_r_5") < self.spoilerTolerance and
      (ipc.readLvar("FSLA320_elevator_l") < self.elevatorTolerance or (ipc.readLvar("FSLA320_elevator_l") >= 1500 and ipc.readLvar("FSLA320_elevator_l") - 1500 < self.elevatorTolerance)) and
      (ipc.readLvar("FSLA320_elevator_r") < self.elevatorTolerance or (ipc.readLvar("FSLA320_elevator_r") >= 1500 and ipc.readLvar("FSLA320_elevator_r") - 1500 < self.elevatorTolerance))
   end,

   rudNeutral = function(self)
      return (ipc.readLvar("FSLA320_rudder") < self.rudderTolerance or (ipc.readLvar("FSLA320_rudder") >= 1500 and ipc.readLvar("FSLA320_rudder") - 1500 < self.rudderTolerance))
   end
}

-- Main ---------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

setmetatable(callouts,callouts)
setmetatable(callouts.flightControlsCheck,callouts.flightControlsCheck)

sound.path(sound_path)

if enable_actions == 1 then
   ipc.set("PMA_SOP", SOP)
   ipc.set("PMA_PM", PM)
   ipc.set("PMA_after_start", after_start)
   ipc.set("PMA_lineup", lineup)
   ipc.set("PMA_after_takeoff", after_takeoff)
   ipc.set("PMA_landing", landing)
   ipc.set("PMA_packs_on_takeoff", packs_on_takeoff)
   ipc.set("PMA_pack2_off_after_landing", PMA_pack2_off_after_landing)
   ipc.runlua("PM_actions")
end

--log the plugin startup
do
   local play_V1 = play_V1
   local PM = PM
   if PM == 1 then
      PM = "Captain"
   else
      PM = "First Officer"
   end
   if play_V1 == 1 then
      play_V1 = "Yes"
   else
      play_V1 = "No"
   end
   log(">>>>>> script started <<<<<<")
   log("user option 'Play V1 callout': " .. play_V1)
   log("user option 'Pilot Monitoring': " .. PM)
   local msg = "\n'Pilot Monitoring Callouts' plug-in started.\n\n\nSelected options:\n\nPlay V1 callout: " .. play_V1 .. "\n\nCallout volume: " .. volume .. "%" .. "\n\nPilot Monitoring : " .. PM
   if display_startup_message == 1 then ipc.display(msg,20) end
end

--running the callouts function in an infinite loop
while true do callouts() end
