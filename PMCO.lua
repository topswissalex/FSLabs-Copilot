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
local readLvar = ipc.readLvar
local currTime = ipc.elapsedtime

local sound_path = "..\\Modules\\PMCO_Sounds\\" 
local loopCycleCritical = 100
local loopCycleResting = 1000
local PFD_delay = 650
local ECAM_delay = 300
local TL_takeoffThreshold = 26
local TL_reverseThreshold = 100
local reverserDoorThreshold = 90
local spoilersDeployedThreshold = 200
local previousCalloutEndTime
local reactionTime = 300
local logging = true
local firstRun = true

-- Logging ------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local logname = "Pilot Monitoring Callouts.log"
io.open(logname,"w"):close()

function log(str,onlyMsg) -- Calling this function from a coroutine results in a crash
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
   local prefix = "PMCO: "
   if onlyMsg then timestamp = "" prefix = "" end
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
function timePassedSince(ref) return currTime() - ref end
function reverseSelected() return readLvar("VC_PED_TL_1") > 100 and readLvar("VC_PED_TL_2") > 100 end

function thrustLeversSetForTakeoff()
   local TL1, TL2 = readLvar("VC_PED_TL_1"), readLvar("VC_PED_TL_2")
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

function getTakeoffSpeedsFromMCDU()
   FSL.PED_MCDU_KEY_PERF()
   ipc.sleep(500)
   local V1 = tonumber(FSL.MCDU.getDisplay(PM,49,51))
   local Vr = tonumber(FSL.MCDU.getDisplay(PM,97,99))
   ipc.sleep(1000)
   FSL.PED_MCDU_KEY_FPLN()
   if not V1 then log("V1 hasn't been entered") end
   if not Vr then log("Vr hasn't been entered") end
   return V1, Vr
end

function play(fileName,length)
   if previousCalloutEndTime and previousCalloutEndTime - currTime() > 0 then
      ipc.sleep(previousCalloutEndTime - currTime())
   end
   sound.play(fileName,sound_device,volume)
   if length then previousCalloutEndTime = currTime() + length
   else previousCalloutEndTime = nil end
end

local callouts = {

   init = function(self)
      log("Initializing")
      self.airborne = not onGround()
      self.skipChecks = onGround() and enginesRunning() and not firstRun
      self.takeoffAbortedAtTime = nil
      self.latestTouchdownAtTime = nil
      self.landedAtTime = nil
      self.noReverseTimeRef = nil
      self.noDecelTimeRef = nil
      self.reverseFuncEndedAtTime = nil
      self.brakesChecked = false
      self.flightControlsChecked = false
      ipc.set("brakesChecked", nil)
      ipc.set("flightControlsChecked", nil)
      firstRun = false
      if self.skipChecks then log("Skipping flight controls and brake checks until the engines are shut down") end
   end,

   __call = function(self)

      if not self.falseTrigger then self:init() end

      while onGround() and not enginesRunning() do restingLoop() end

      if onGround() and not self.skipChecks then
         local co_flightControlsCheck = coroutine.create(function() self:flightControlsCheck() end)
         local co_brakeCheck = coroutine.create(function() self:brakeCheck() end)
         repeat ipc.sleep(5)
            local flightControlsCheckedOrSkipped = not coroutine.resume(co_flightControlsCheck)
            local brakesCheckedOrSkipped = not coroutine.resume(co_brakeCheck)
         until flightControlsCheckedOrSkipped and brakesCheckedOrSkipped
         if self.brakesChecked then log("Brakes are checked") end
         if self.flightControlsChecked then log("flightControlsChecked") end
      end

      if onGround() then
         while not thrustLeversSetForTakeoff() do
            if not enginesRunning() then return end
            restingLoop()
         end
         local tookOffOrAborted, enginesShutdown = self:takeoff()
         self.falseTrigger = not tookOffOrAborted and not enginesShutdown
         if self.falseTrigger or enginesShutdown then return end
      elseif self.circuit then
         log("Doing circuits")
         repeat
            criticalLoop()
            self.circuit = not self:positiveClimb()
         until not self.circuit
      end

      while not onGround() do
         if not self.airborne then self.airborne = true end
         if ALT() > 100 then restingLoop() else criticalLoop() end
      end

      if self.airborne then self.latestTouchdownAtTime = currTime() end

      if groundSpeed() > 60 then self:rollout() end

   end,

   doingCircuits = function(self)
      self.circuit = thrustLeversSetForTakeoff() and not onGround()
      return self.circuit
   end,

   takeoffCancelled = function (self)
      local waitUntilCancel = 10000
      if not thrustLeversSetForTakeoff() then
         local aborted = self.takeoffThrustWasSet and groundSpeed() > 10 and (FSL.getThrustLeversPos() == "IDLE" or reverseSelected())
         if aborted then
            log("Takeoff aborted")
            self.takeoffThrustWasSet = false
            self.cancelCountDownStart = nil
            self.takeoffAbortedAtTime = currTime()
            return false, true 
         end
         if not self.cancelCountDownStart then
            self.cancelCountDownStart = currTime()
         elseif currTime() - self.cancelCountDownStart > waitUntilCancel then
            log("Cancelling the takeoff logic because the thrust levers were moved back for longer than " .. waitUntilCancel / 1000 .. " seconds")
            self.cancelCountDownStart = nil
            self.takeoffThrustWasSet = false
            return true
         end
      elseif self.cancelCountDownStart then self.cancelCountDownStart = nil end
   end,

   takeoff = function(self)

      log("Takeoff")

      local V1Select, VrSelect = getTakeoffSpeedsFromMCDU()

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         criticalLoop()
      until self:thrustSet()

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         criticalLoop()
      until self:oneHundred()

      if play_V1 == 1 then
         repeat
            local falseTrigger, aborted = self:takeoffCancelled()
            if falseTrigger then return false
            elseif aborted then return true
            elseif not enginesRunning() then return nil, true end
            criticalLoop()
         until self:V1(V1Select)
      end

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         criticalLoop()
      until self:rotate(VrSelect)

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         criticalLoop()
      until self:positiveClimb()

      return true

   end,

   checkIfLanded = function(self)
      if not onGround() then self.latestTouchdownAtTime = nil
      elseif not self.latestTouchdownAtTime then self.latestTouchdownAtTime = currTime()
      elseif currTime() - self.latestTouchdownAtTime > 500 then
         log("Landed")
         self.landedAtTime = currTime()
      end
   end,

   rollout = function(self)

      if not self.takeoffAbortedAtTime then
         repeat
            if not self.landedAtTime then self:checkIfLanded() end
            criticalLoop()
         until self:spoilers()
      else
         self.landedAtTime = self.takeoffAbortedAtTime 
      end

      repeat
         if not self.landedAtTime then self:checkIfLanded() end
         criticalLoop()
      until self:reverseGreen()

      if groundSpeed() > 70 then 
         while not self.landedAtTime do self:checkIfLanded() criticalLoop() end
         self.noDecelTimeRef = currTime()
         repeat criticalLoop() until self:decel() 
      end

      repeat criticalLoop() until self:seventy()
   end,

   thrustSet = function(self)
      local thrustSet = ALT() < 10 and takeoffThrustIsSet()
      local skipThis = not thrustSet and IAS() > 80
      if thrustSet then
         self.takeoffThrustWasSet = true
         ipc.sleep(800) -- wait for further spool up
         play("thrustSet")
         log("Thrust set")
      elseif skipThis then
         log("Thrust set skipped (IAS > 80 kts)")
      end
      return thrustSet or skipThis
   end,

   oneHundred = function(self)
      local oneHundred = ALT() < 10 and IAS() >= 100
      if oneHundred then
         ipc.sleep(PFD_delay)
         play("oneHundred")
         log("Reached 100 kts")
      end
      return oneHundred
   end,

   V1 = function(self,V1Select)
      if not V1Select then return true
      else V1Select = V1Select - V1_timing end
      local V1 = ALT() < 10 and IAS() >= V1Select
      if V1 then
         ipc.sleep(PFD_delay)
         play("v1", 700)
         log("Reached V1")
      end
      return V1
   end,

   rotate = function(self,VrSelect)
      if not VrSelect then return true end
      local rotate = ALT() < 10 and IAS() >= VrSelect
      if rotate then
         ipc.sleep(PFD_delay)
         play("rotate")
         log("Reached Vr")
      end
      return rotate
   end,

   positiveClimb = function(self)
      local verticalSpeed = ipc.readSW(0x02C8) * 60 * 3.28084 / 256
      local positiveClimb = ALT() >= 10 and verticalSpeed >= 500
      local skipThis = not positiveClimb and ALT() > 150.0
      if positiveClimb then
         play("positiveClimb")
         log("Positive climb")
      elseif skipThis then
         log("Positive climb skipped (ALT > 500ft)")
      end
      return positiveClimb or skipThis
   end,

   spoilers = function(self)
      local spoilers_left = readLvar("FSLA320_spoiler_l_1") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_l_2") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_l_3") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_l_4") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_l_5") > spoilersDeployedThreshold
      local spoilers_right = readLvar("FSLA320_spoiler_r_1") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_r_2") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_r_3") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_r_4") > spoilersDeployedThreshold and readLvar("FSLA320_spoiler_r_5") > spoilersDeployedThreshold
      local spoilers = spoilers_left and spoilers_right
      local noSpoilers = not spoilers and self.landedAtTime and timePassedSince(self.landedAtTime) > 5000
      if spoilers then
         log("Spoilers deployed") 
         ipc.sleep(ECAM_delay + reactionTime)
         if prob(0.1) then ipc.sleep(plusminus(500)) end
         play("spoilers",900)
      elseif noSpoilers then
         log("Spoilers didn't deploy :(")
      end
      return spoilers or noSpoilers or self:doingCircuits()
   end,

   reverseGreen = function(self)
      local reverseGreen = readLvar("FSLA320_reverser_left") >= reverserDoorThreshold and readLvar("FSLA320_reverser_right") >= reverserDoorThreshold
      local noReverse = (not reverseGreen and self.noReverseTimeRef and timePassedSince(self.noReverseTimeRef) > 5000) or groundSpeed() < 100
      if self.landedAtTime and reverseSelected() and not self.noReverseTimeRef then 
         self.noReverseTimeRef = currTime() 
      end
      if reverseGreen then
         log("Reverse is green")
         ipc.sleep(ECAM_delay + reactionTime)
         if prob(0.1) then ipc.sleep(plusminus(500)) end
         play("reverseGreen",900)
      elseif noReverse then
         noReverse = true
         log("Reverse isn't green :(")
      end
      return reverseGreen or noReverse or self:doingCircuits()
   end,

   decel = function(self)
      local noDecel
      local accelLateral = ipc.readDBL(0x3070)
      local decel = accelLateral < -4
      local noDecel = (not decel and timePassedSince(self.noDecelTimeRef) > 5000) or groundSpeed() < 70
      if decel then
         log("Decel")
         ipc.sleep(plusminus(1200))
         if prob(0.1) then ipc.sleep(plusminus(500)) end
         play("decel",600)
      elseif noDecel then
         log("No decel :(")
      end
      return decel or noDecel or self:doingCircuits()
   end,

   seventy = function(self)
      local seventy = groundSpeed() <= 70
      if seventy then
         ipc.sleep(plusminus(200))
         if prob(0.05) then ipc.sleep(plusminus(200)) end
         play("seventy")
         log("70 knots")
      end
      return seventy or self:doingCircuits()
   end,

   brakeCheck = function(self)

      if PM_announces_brake_check == 0 then return end
      sound.path(sound_path)

      repeat

         if thrustLeversSetForTakeoff() then return end

         local leftBrakeApp = ipc.readUW(0x0BC4) * 100 / 16383
         local rightBrakeApp = ipc.readUW(0x0BC6) * 100 / 16383
         local leftPressure = readLvar("VC_MIP_BrkPress_L")
         local rightPressure = readLvar("VC_MIP_BrkPress_R")
         local pushback = readLvar("FSLA320_NWS_Pin") == 1
         local brakeAppThreshold = 1
         local brakesChecked

         if not pushback and groundSpeed() > 0.5 and leftBrakeApp > brakeAppThreshold and rightBrakeApp > brakeAppThreshold then
            ipc.sleep(2000)
            if leftBrakeApp > brakeAppThreshold and rightBrakeApp > brakeAppThreshold then
               if leftPressure == 0 and rightPressure == 0 then
                  play("pressureZero")
                  brakesChecked = true
               elseif leftPressure > 0 or rightPressure > 0 then
                  return
               end
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

   randomDelay = function()
      ipc.sleep(plusminus(150))
      if prob(0.2) then ipc.sleep(100) end
   end,

   __call = function(self)

      if PM_announces_flightcontrol_check == 0 then return end

      local fullLeft, fullRight, fullLeftRud, fullRightRud, fullUp, fullDown, xNeutral, yNeutral, rudNeutral
      sound.path(sound_path)
      
      repeat

         if thrustLeversSetForTakeoff() then return end

         -- full left aileron
         if not fullLeft and not ((fullUp or fullDown) and not yNeutral) and self:fullLeft() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("fullLeft_1")
            fullLeft = true
         end

         -- full right aileron
         if not fullRight and not ((fullUp or fullDown) and not yNeutral) and self:fullRight() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("fullRight_1")
            fullRight = true
         end

         -- neutral after full left and full right aileron
         if fullLeft and fullRight and not xNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("neutral_1")
            xNeutral = true
         end

         -- full up
         if not fullUp and not ((fullLeft or fullRight) and not xNeutral) and self:fullUp() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("fullUp")
            fullUp = true
         end

         -- full down
         if not fullDown and not ((fullLeft or fullRight) and not xNeutral) and self:fullDown() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("fullDown")
            fullDown = true
         end

         -- neutral after full up and full down
         if fullUp and fullDown and not yNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("neutral_2")
            yNeutral = true
         end

         -- full left rudder
         if not fullLeftRud and xNeutral and yNeutral and self:fullLeftRud() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("fullLeft_2")
            fullLeftRud = true
         end

         -- full right rudder
         if not fullRightRud and xNeutral and yNeutral and self:fullRightRud() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("fullRight_2")
            fullRightRud = true
         end

         -- neutral after full left and full right rudder
         if fullLeftRud and fullRightRud and not rudNeutral and self:rudNeutral() then
            ipc.sleep(ECAM_delay)
            self.randomDelay()
            play("neutral_3")
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
      if readLvar("FSLA320_flap_l_1") == 0 then
         aileronLeft = readLvar("FSLA320_aileron_l") <= 1499 and 1499 - readLvar("FSLA320_aileron_l") < self.aileronTolerance
      elseif readLvar("FSLA320_flap_l_1") > 0 then
         aileronLeft = readLvar("FSLA320_aileron_l") <= 1199 and 1199 - readLvar("FSLA320_aileron_l") < self.aileronTolerance
      end
      return
      aileronLeft and
      1500 - readLvar("FSLA320_spoiler_l_2") < self.spoilerTolerance and
      1500 - readLvar("FSLA320_spoiler_l_3") < self.spoilerTolerance and
      1500 - readLvar("FSLA320_spoiler_l_4") < self.spoilerTolerance and
      1500 - readLvar("FSLA320_spoiler_l_5") < self.spoilerTolerance
   end,

   fullRight = function(self)
      local aileronRight
      if readLvar("FSLA320_flap_l_1") == 0 then
         aileronRight = 3000 - readLvar("FSLA320_aileron_r") < self.aileronTolerance
      elseif readLvar("FSLA320_flap_l_1") > 0 then
         aileronRight = 2700 - readLvar("FSLA320_aileron_r") < self.aileronTolerance
      end
      return
      aileronRight and
      1500 - readLvar("FSLA320_spoiler_r_2") < self.spoilerTolerance and
      1500 - readLvar("FSLA320_spoiler_r_3") < self.spoilerTolerance and
      1500 - readLvar("FSLA320_spoiler_r_4") < self.spoilerTolerance and
      1500 - readLvar("FSLA320_spoiler_r_5") < self.spoilerTolerance
   end,

   fullUp = function(self)
      return
      readLvar("FSLA320_elevator_l") <= 1499 and 1499 - readLvar("FSLA320_elevator_l") < self.elevatorTolerance and
      readLvar("FSLA320_elevator_r") <= 1499 and 1499 - readLvar("FSLA320_elevator_r") < self.elevatorTolerance
   end,

   fullDown = function(self)
      return
      3000 - readLvar("FSLA320_elevator_l") < self.elevatorTolerance and
      3000 - readLvar("FSLA320_elevator_r") < self.elevatorTolerance
   end,

   fullLeftRud = function(self)
      return readLvar("FSLA320_rudder") < 1500 and 1500 - readLvar("FSLA320_rudder") < self.rudderTolerance
   end,

   fullRightRud = function(self)
      return 3000 - readLvar("FSLA320_rudder") < self.rudderTolerance
   end,

   stickNeutral = function(self)
      local aileronsNeutral
      if readLvar("FSLA320_flap_l_1") == 0 then
         aileronsNeutral = (readLvar("FSLA320_aileron_l") < self.aileronTolerance or (readLvar("FSLA320_aileron_l") >= 1500 and readLvar("FSLA320_aileron_l") - 1500 < self.aileronTolerance)) and
                           (readLvar("FSLA320_aileron_r") < self.aileronTolerance or (readLvar("FSLA320_aileron_r") >= 1500 and readLvar("FSLA320_aileron_r") - 1500 < self.aileronTolerance))
      elseif readLvar("FSLA320_flap_l_1") > 0 then
         aileronsNeutral = math.abs(readLvar("FSLA320_aileron_l") - 1980) < self.aileronTolerance and math.abs(readLvar("FSLA320_aileron_r") - 480) < self.aileronTolerance
      end
      return
      aileronsNeutral and
      readLvar("FSLA320_spoiler_l_2") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_l_3") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_l_4") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_l_5") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_r_2") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_r_3") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_r_4") < self.spoilerTolerance and
      readLvar("FSLA320_spoiler_r_5") < self.spoilerTolerance and
      (readLvar("FSLA320_elevator_l") < self.elevatorTolerance or (readLvar("FSLA320_elevator_l") >= 1500 and readLvar("FSLA320_elevator_l") - 1500 < self.elevatorTolerance)) and
      (readLvar("FSLA320_elevator_r") < self.elevatorTolerance or (readLvar("FSLA320_elevator_r") >= 1500 and readLvar("FSLA320_elevator_r") - 1500 < self.elevatorTolerance))
   end,

   rudNeutral = function(self)
      return (readLvar("FSLA320_rudder") < self.rudderTolerance or (readLvar("FSLA320_rudder") >= 1500 and readLvar("FSLA320_rudder") - 1500 < self.rudderTolerance))
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
   log(">>>>>> Script started <<<<<<")
   log("Play V1 callout: " .. play_V1)
   log("Pilot Monitoring: " .. PM)
   log("----------------------------------------------------------------------------------------",1)
   log("----------------------------------------------------------------------------------------",1)
   local msg = "\n'Pilot Monitoring Callouts' plug-in started.\n\n\nSelected options:\n\nPlay V1 callout: " .. play_V1 .. "\n\nCallouts volume: " .. volume .. "%" .. "\n\nPilot Monitoring : " .. PM
   if show_startup_message == 1 then ipc.display(msg,20) end
end

while true do callouts() end
