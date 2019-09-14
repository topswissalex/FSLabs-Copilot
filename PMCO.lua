-- "PMCO - Pilot Monitoring Callouts" FREEWARE LUA script
-- Version:
-- by Nils Unger, Peter Pukhnoy

-- ##################################################################
-- ############ EDIT USER OPTIONS HERE ##############################
-- ##################################################################

-- Callouts:

play_V1 = 1 -- play V1 sound? 0 = no, 1 = yes
V1_timing = 0 -- V1 will be announced at the speed of V1 - V1_timing. If you want V1 to be announced slightly before V1 is reached on the PFD, type the number of knots.
PM = 2 -- Pilot Monitoring: 1 = Captain, 2 = First Officer
show_startup_message = 1 -- show startup message? 0 = no, 1 = yes
sound_device = 0 -- zero is default (only change this when no sound is played)
volume = 65 -- volume of all callouts (zero does NOT mean silenced, just rather quiet)
PM_announces_flightcontrol_check = 1 -- PM announces 'full left', 'full right' etc.
PM_announces_brake_check = 1 -- PM announces 'brake pressure zero' after the brake check. The trigger is the first application of the brakes after you start moving

-- Actions:

enable_actions = 0 -- allow the PM to perform the procedures that are listed below
SOP = "default"

-- Enable or disable individual procedures in the default SOP and change their related options:

after_start = 1 -- triggered when at least one engine is running and the engine mode selector is in the 'NORM' position
during_taxi = 1 -- the PM will press the AUTO BRK and TO CONFIG buttons after you've done the brake and flight controls checks
lineup = 1 -- triggered by cycling the seat belts sign switch twice within 2 seconds
after_takeoff = 1 -- triggered by moving the thrust levers back into the 'CLB' detent
after_landing = 1 -- triggered when the ground speed is less than 30 kts and you have disarmed the spoilers

packs_on_takeoff = 0 -- 1 = takeoff with the packs on. This option will be ignored if a performance request is found in the ATSU log
pack2_off_after_landing = 0

-- ##################################################################
-- ############### END OF USER OPTIONS ##############################
-- ##################################################################

-- Do not edit below this line ----------------------------------------------------------
-----------------------------------------------------------------------------------------

pilot = PM
noPauses = true
local FSL = require("FSL")

local sound_path = "..\\Modules\\PMCO_Sounds\\" 
local loopCycleCritical = 100
local loopCycleResting = 1000
local PFD_delay = 650
local ECAM_delay = 3000
local TL_takeoffThreshold = 26
local TL_reverseThreshold = 100
local reverserDoorThreshold = 90
local spoilersDeployedThreshold = 200
local previousCalloutEndTime
local reactionTime = 300

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
function ALT() return ipc.readUD(0x31E4) / 65536 end
function IAS() return ipc.readUW(0x02BC) / 128 end
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

function takeoffThrustIsSet()
   local eng1_N1 = ipc.readUW(0x0898) * 100 / 16384
   local eng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   return eng1_N1 > 80 and eng2_N1 > 80
end

function play(fileName,length)
   if previousCalloutEndTime and previousCalloutEndTime - ipc.elapsedtime() > 0 then
      ipc.sleep(previousCalloutEndTime - ipc.elapsedtime())
   end
   sound.play(fileName,sound_device,volume)
   if length then previousCalloutEndTime = ipc.elapsedtime() + length
   else previousCalloutEndTime = nil end
end

function reverseSelected()
   return (FSL.getThrustLeversPos(1) == "REV_IDLE" and FSL.getThrustLeversPos(2) == "REV_IDLE") or (FSL.getThrustLeversPos(1) == "REV_MAX" and FSL.getThrustLeversPos(2) == "REV_MAX")
end

local callouts = {

   init = function(self)
      self.airborne = not onGround()
      self.reverseSelectedAtTime = nil
      self.landedAtTime = nil
      self.takeoffAbortedAtTime = nil
      ipc.set("flightControlsChecked", nil)
      ipc.set("brakesChecked", nil)
   end,

   __call = function(self)

      if not self.falseTrigger then self:init() end

      repeat
         if not enginesRunning() then self.skipChecks = false end
         restingLoop()
      until enginesRunning()

      if onGround() and not self.skipChecks then
         local flightControlsCheckOrSkip = coroutine.create(function() self:flightControlsCheck() end)
         local brakeCheckOrSkip = coroutine.create(function() self:brakeCheck() end)
         repeat ipc.sleep(5)
         until not coroutine.resume(flightControlsCheckOrSkip) and not coroutine.resume(brakeCheckOrSkip)
      end

      if onGround() then 
         repeat 
            local takeoff = self:takeoff()
            local abortedTakeoff = not takeoff and self.takeoffAbortedAtTime
            self.falseTrigger = not takeoff and not abortedTakeoff
            if self.falseTrigger or not enginesRunning() then return end
            restingLoop()
         until takeoff or abortedTakeoff
      end

      while not onGround() do
         if not self.airborne then self.airborne = true end
         if ALT() > 100 then restingLoop() else criticalLoop() end
      end

      if self.airborne then self.landedAtTime = ipc.elapsedtime() end

      if groundSpeed() > 60 then self:rollout() end

      self.skipChecks = true

   end,

   takeoffCancelled = function (self)
      local waitUntilCancel = 10000
      if not thrustLeversSetForTakeoff() then
         local aborted = takeoffThrustIsSet() and groundSpeed() > 10 and (FSL.getThrustLeversPos(1) == "IDLE" and FSL.getThrustLeversPos(2) == "IDLE") or (FSL.getThrustLeversPos(1) == "REV_IDLE" and FSL.getThrustLeversPos(2) == "REV_IDLE") or (FSL.getThrustLeversPos(1) == "REV_MAX" and FSL.getThrustLeversPos(2) == "REV_MAX")
         if aborted then
            self.takeoffAbortedAtTime = ipc.elapsedtime()
            self.cancelCountDownStart = nil
            return true 
         end
         if not self.cancelCountDownStart then
            self.cancelCountDownStart = ipc.elapsedtime()
         elseif ipc.elapsedtime() - self.cancelCountDownStart > waitUntilCancel then
            log("Cancelling the takeoff logic because the thrust levers were moved back for longer than " .. waitUntilCancel / 1000 .. " seconds")
            self.cancelCountDownStart = nil
            return true
         end
      elseif self.cancelCountDownStart then self.cancelCountDownStart = nil end
   end,

   takeoff = function(self)

      while not thrustLeversSetForTakeoff() do restingLoop() end

      FSL.PED_MCDU_KEY_PERF()
      ipc.sleep(500)
      local V1Select = tonumber(FSL.MCDU.getDisplay(PM,49,51))
      local VrSelect = tonumber(FSL.MCDU.getDisplay(PM,97,99))
      ipc.sleep(1000)
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
      if self.landedAtTime then repeat criticalLoop() until self:spoilers() end
      repeat criticalLoop() until self:reverseGreen()
      if groundSpeed() > 70 then repeat criticalLoop() until self:decel() end
      repeat criticalLoop() until self:seventy()
   end,

   thrustSet = function(self)
      local thrustSet, skipThis
      if ALT() < 10 and takeoffThrustIsSet() then
         thrustSet = true
         ipc.sleep(800) -- wait for further spool up
         play("thrustSet")
         log("Thrust set")
      elseif IAS() > 80 then
         skipThis = true
         log("thrust set skipped (IAS > 80 kts)")
      end
      return thrustSet or skipThis
   end,

   oneHundred = function(self)
      local oneHundred
      if ALT() < 10 and IAS() >= 100 then
         oneHundred = true
         ipc.sleep(PFD_delay)
         play("oneHundred")
         log("reached 100 kts")
      end
      return oneHundred
   end,

   V1 = function(self,V1Select)
      local V1
      if ALT() < 10 and IAS() >= V1Select then
         V1 = true
         ipc.sleep(PFD_delay)
         play("v1", 900)
         log("reached V1")
      end
      return V1
   end,

   rotate = function(self,VrSelect)
      local rotate
      if ALT() < 10 and IAS() >= VrSelect then
         rotate = true
         ipc.sleep(PFD_delay)
         play("rotate")
         log("reached Vr")
      end
      return rotate
   end,

   positiveClimb = function(self)
      local positiveClimb, skipThis
      local vertSpeed = ipc.readSW(0x02C8) * 60 * 3.28084 / 256
      if ALT() >= 10 and vertSpeed >= 500 then
         positiveClimb = true
         play("positiveClimb")
         log("reached positive climb")
      elseif ALT() > 150.0 then -- skip criterium: 150m / 500ft
         skipThis = true
         log("positive climb skipped (ALT > 500ft)")
      end
      return positiveClimb or skipThis
   end,

   spoilers = function(self)
      local spoilers_left = ipc.readLvar("FSLA320_spoiler_l_2") > spoilersDeployedThreshold and ipc.readLvar("FSLA320_spoiler_l_3") > spoilersDeployedThreshold and ipc.readLvar("FSLA320_spoiler_l_4") > spoilersDeployedThreshold and ipc.readLvar("FSLA320_spoiler_l_5") > spoilersDeployedThreshold
      local spoilers_right = ipc.readLvar("FSLA320_spoiler_r_2") > spoilersDeployedThreshold and ipc.readLvar("FSLA320_spoiler_r_3") > spoilersDeployedThreshold and ipc.readLvar("FSLA320_spoiler_r_4") > spoilersDeployedThreshold and ipc.readLvar("FSLA320_spoiler_r_5") > spoilersDeployedThreshold
      local spoilers = spoilers_left and spoilers_right
      local noSpoilers
      if not spoilers and onGround() and timePassedSince(self.landedAtTime) > 5000 then 
         noSpoilers = true
      end
      if noSpoilers then log("spoilers didn't deploy :(") 
      elseif spoilers then
         log("spoilers deployed") 
         ipc.sleep(ECAM_delay + reactionTime)
         play("spoilers",900)
      end
      return spoilers or noSpoilers
   end,

   reverseGreen = function(self)
      local reverseGreen = ipc.readLvar("FSLA320_reverser_left") >= reverserDoorThreshold and ipc.readLvar("FSLA320_reverser_right") >= reverserDoorThreshold
      local noReverse
      if reverseSelected() and not self.reverseSelectedAtTime then 
         self.reverseSelectedAtTime = ipc.elapsedtime() 
      end
      if self.reverseSelectedAtTime and not reverseGreen and timePassedSince(self.reverseSelectedAtTime) > 5000 then
         noReverse = true
         log("reverse isn't green :(")
      end
      if reverseGreen then
         log("reverse is green")
         ipc.sleep(ECAM_delay + reactionTime)
         play("reverseGreen",900)
      end
      return reverseGreen or noReverse
   end,

   decel = function(self)
      local noDecel
      local accelLateral = ipc.readDBL(0x3070)
      local decel = accelLateral < -4
      if decel then
         decel = true
         log("decel")
         ipc.sleep(ECAM_delay + reactionTime)
         play("decel",600)
      elseif timePassedSince(self.landedAtTime or self.takeoffAbortedAtTime) > 10000 then
         noDecel = true
         log("no decel")
      end
      return decel or noDecel
   end,

   seventy = function(self)
      local seventy
      if groundSpeed() <= 70 then
         seventy = true
         ipc.sleep(ECAM_delay + reactionTime)
         play("seventy")
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
               play("pressureZero")
               brakesChecked = true
            end
         end

         coroutine.yield()
         
      until brakesChecked

      ipc.set("brakesChecked",1)

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
            play("fullLeft1")
            fullLeft = true
         end

         -- full right aileron
         if not fullRight and not ((fullUp or fullDown) and not yNeutral) and self:fullRight() then
            ipc.sleep(ECAM_delay)
            play("fullRight1")
            fullRight = true
         end

         -- neutral after full left and full right aileron
         if fullLeft and fullRight and not xNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            play("neutral1")
            xNeutral = true
         end

         -- full up
         if not fullUp and not ((fullLeft or fullRight) and not xNeutral) and self:fullUp() then
            ipc.sleep(ECAM_delay)
            play("fullUp")
            fullUp = true
         end

         -- full down
         if not fullDown and not ((fullLeft or fullRight) and not xNeutral) and self:fullDown() then
            ipc.sleep(ECAM_delay)
            play("fullDown")
            fullDown = true
         end

         -- neutral after full up and full down
         if fullUp and fullDown and not yNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            play("neutral2")
            yNeutral = true
         end

         -- full left rudder
         if not fullLeftRud and xNeutral and yNeutral and self:fullLeftRud() then
            ipc.sleep(ECAM_delay)
            play("fullLeft2")
            fullLeftRud = true
         end

         -- full right rudder
         if not fullRightRud and xNeutral and yNeutral and self:fullRightRud() then
            ipc.sleep(ECAM_delay)
            play("fullRight2")
            fullRightRud = true
         end

         -- neutral after full left and full right rudder
         if fullLeftRud and fullRightRud and not rudNeutral and self:rudNeutral() then
            ipc.sleep(ECAM_delay)
            play("neutral3")
            rudNeutral = true
         end

         if not fullLeft and not fullRight and not fullUp and not fullDown and not fullLeftRud and not fullRightRud then
            coroutine.yield()
         end

      until xNeutral and yNeutral and rudNeutral

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
   local msg = "\n'Pilot Monitoring Callouts' plug-in started.\n\n\nSelected options:\n\nPlay V1 callout: " .. play_V1 .. "\n\nCallouts volume: " .. volume .. "%" .. "\n\nPilot Monitoring : " .. PM
   if show_startup_message == 1 then ipc.display(msg,20) end
end

while true do callouts() end
