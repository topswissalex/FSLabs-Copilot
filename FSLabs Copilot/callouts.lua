require "FSLabs Copilot"

local FSL = FSL
local readLvar = readLvar
local currTime = currTime
local sleep = sleep

local PFD_delay = 650
local ECAM_delay = 300
local reverserDoorThreshold = 90
local spoilersDeployedThreshold = 200
local reactionTime = 300

-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local callouts = {

   init = function(self)
      if not self.firstRun then log("RESETTING") end
      self.airborne = not onGround()
      self.takeoffAbortedAtTime = nil
      self.latestTouchdownAtTime = nil
      self.landedAtTime = nil
      self.noReverseTimeRef = nil
      self.noDecelTimeRef = nil
      self.reverseFuncEndedAtTime = nil
      self.brakesChecked = (onGround() and enginesRunning() and not self.firstRun) or false
      self.flightControlsChecked = (onGround() and enginesRunning() and not self.firstRun) or false
      if not self.brakesChecked then ipc.set("brakesChecked", nil) else ipc.set("brakesChecked", 1) end
      if not self.flightControlsChecked then ipc.set("flightControlsChecked", nil) else ipc.set("flightControlsChecked", 1) end
      self.firstRun = false
   end,

   main = function(self)

      if not self.falseTrigger then self:init() end

      while onGround() and not enginesRunning() do sleep() end

      if onGround() then
         local co_flightControlsCheck = coroutine.create(function() self:flightControlsCheck() end)
         local co_brakeCheck = coroutine.create(function() self:brakeCheck() end)
         repeat sleep(5)
            local flightControlsCheckedOrSkipped = self.flightControlsChecked or not coroutine.resume(co_flightControlsCheck)
            local brakesCheckedOrSkipped = self.brakesChecked or not coroutine.resume(co_brakeCheck)
         until flightControlsCheckedOrSkipped and brakesCheckedOrSkipped
      end

      if onGround() then
         while not thrustLeversSetForTakeoff() do
            if not enginesRunning() then return end
            sleep()
         end
         local tookOffOrAborted, enginesShutdown = self:takeoff()
         self.falseTrigger = not tookOffOrAborted and not enginesShutdown
         if self.falseTrigger or enginesShutdown then return end
      elseif self.circuit then
         log("Doing circuits")
         repeat
            sleep()
            self.circuit = not self:positiveClimb()
         until not self.circuit
      end

      while not onGround() do
         if not self.airborne then self.airborne = true end
         sleep()
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
         sleep()
      until self:thrustSet()

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         sleep()
      until self:oneHundred()

      if play_V1 == 1 then
         repeat
            local falseTrigger, aborted = self:takeoffCancelled()
            if falseTrigger then return false
            elseif aborted then return true
            elseif not enginesRunning() then return nil, true end
            sleep()
         until self:V1(V1Select)
      end

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         sleep()
      until self:rotate(VrSelect)

      repeat
         local falseTrigger, aborted = self:takeoffCancelled()
         if falseTrigger then return false
         elseif aborted then return true
         elseif not enginesRunning() then return nil, true end
         sleep()
      until self:positiveClimb()

      return true

   end,

   checkIfLanded = function(self)
      if not onGround() then
         self.latestTouchdownAtTime = nil
      elseif not self.latestTouchdownAtTime then 
         self.latestTouchdownAtTime = currTime()
      elseif currTime() - self.latestTouchdownAtTime > 500 then
         log("Landed")
         self.landedAtTime = currTime()
      end
   end,

   rollout = function(self)

      -- spoilers
      if not self.takeoffAbortedAtTime then
         repeat
            if self:doingCircuits() then return end
            if not self.landedAtTime then self:checkIfLanded() end
            sleep()
         until self:spoilers()
      else
         self.landedAtTime = self.takeoffAbortedAtTime 
      end

      -- reverse green
      repeat
         if self:doingCircuits() then return end
         if not self.landedAtTime then self:checkIfLanded() end
         sleep()
      until self:reverseGreen()

      -- decel
      if groundSpeed() > 70 then 
         while not self.landedAtTime do self:checkIfLanded() sleep() end
         self.noDecelTimeRef = currTime()
         repeat 
            if self:doingCircuits() then return end
            sleep() 
         until self:decel() 
      end

      -- seventy
      repeat 
         if self:doingCircuits() then return end
         sleep() 
      until self:seventy()
   end,

   thrustSet = function(self)
      local thrustSet = ALT() < 10 and takeoffThrustIsSet()
      local skipThis = not thrustSet and IAS() > 80
      if thrustSet then
         self.takeoffThrustWasSet = true
         sleep(800) -- wait for further spool up
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
         sleep(PFD_delay)
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
         sleep(PFD_delay)
         play("v1", 700)
         log("Reached V1")
      end
      return V1
   end,

   rotate = function(self,VrSelect)
      if not VrSelect then return true end
      local rotate = ALT() < 10 and IAS() >= VrSelect
      if rotate then
         sleep(PFD_delay)
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
      local noSpoilers = not spoilers and self.landedAtTime and timePassedSince(self.landedAtTime) > plusminus(1500)
      if spoilers then
         log("Spoilers deployed") 
         sleep(ECAM_delay + reactionTime)
         if prob(0.1) then sleep(plusminus(500)) end
         play("spoilers",900)
      elseif noSpoilers then
         log("Spoilers didn't deploy :(")
      end
      return spoilers or noSpoilers
   end,

   reverseGreen = function(self)
      local reverseGreen = readLvar("FSLA320_reverser_left") >= reverserDoorThreshold and readLvar("FSLA320_reverser_right") >= reverserDoorThreshold
      local noReverse = (not reverseGreen and self.noReverseTimeRef and timePassedSince(self.noReverseTimeRef) > plusminus(2500,0.2)) or groundSpeed() < 100
      if self.landedAtTime and reverseSelected() and not self.noReverseTimeRef then 
         self.noReverseTimeRef = currTime() 
      end
      if reverseGreen then
         log("Reverse is green")
         sleep(ECAM_delay + reactionTime)
         if prob(0.1) then sleep(plusminus(500)) end
         play("reverseGreen",900)
      elseif noReverse then
         noReverse = true
         log("Reverse isn't green :(")
         log("TL1 = " .. readLvar("VC_PED_TL_1"))
         log("TL2 = " .. readLvar("VC_PED_TL_2"))
         log("Left reverser = " .. readLvar("FSLA320_reverser_left"))
         log("Right reverser = " .. readLvar("FSLA320_reverser_left"))
         log("No reverse time reference: " .. self.noReverseTimeRef)
         log("Time of landing: " .. self.landedAtTime)
         log("Current time: " .. currTime())
      end
      return reverseGreen or noReverse
   end,

   decel = function(self)
      local noDecel
      local accelLateral = ipc.readDBL(0x3070)
      local decel = accelLateral < -4
      local noDecel = (not decel and timePassedSince(self.noDecelTimeRef) > plusminus(1500)) or groundSpeed() < 70
      if decel then
         log("Decel")
         sleep(plusminus(1200))
         if prob(0.1) then sleep(plusminus(500)) end
         play("decel",600)
      elseif noDecel then
         log("No decel :(")
      end
      return decel or noDecel
   end,

   seventy = function(self)
      local seventy = groundSpeed() <= 70
      if seventy then
         sleep(plusminus(200))
         if prob(0.05) then sleep(plusminus(200)) end
         play("seventy")
         log("70 knots")
      end
      return seventy
   end,

   brakeCheck = function(self)

      if PM_announces_brake_check == 0 then return end
      sound.path(sound_path)

      repeat

         if thrustLeversSetForTakeoff() or not enginesRunning() then return end

         local leftBrakeApp = ipc.readUW(0x0BC4) * 100 / 16383
         local rightBrakeApp = ipc.readUW(0x0BC6) * 100 / 16383
         local leftPressure = readLvar("VC_MIP_BrkPress_L")
         local rightPressure = readLvar("VC_MIP_BrkPress_R")
         local pushback = readLvar("FSLA320_NWS_Pin") == 1
         local brakeAppThreshold = 1
         local brakesChecked

         if not pushback and groundSpeed() > 0.5 and leftBrakeApp > brakeAppThreshold and rightBrakeApp > brakeAppThreshold then
            sleep(2000)
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

      self.brakesChecked = true
      ipc.set("brakesChecked",1)
   end
}

callouts.flightControlsCheck = {

   elevatorTolerance = 200,
   aileronTolerance = 300,
   spoilerTolerance = 100,
   rudderTolerance = 100,

   randomDelay = function()
      sleep(plusminus(150))
      if prob(0.2) then sleep(100) end
   end,

   __call = function(self)

      if PM_announces_flightcontrol_check == 0 then return end

      local fullLeft, fullRight, fullLeftRud, fullRightRud, fullUp, fullDown, xNeutral, yNeutral, rudNeutral
      sound.path(sound_path)
      
      repeat

         if thrustLeversSetForTakeoff() or not enginesRunning() then return end

         -- full left aileron
         if not fullLeft and not ((fullUp or fullDown) and not yNeutral) and self:fullLeft() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("fullLeft_1")
            fullLeft = true
         end

         -- full right aileron
         if not fullRight and not ((fullUp or fullDown) and not yNeutral) and self:fullRight() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("fullRight_1")
            fullRight = true
         end

         -- neutral after full left and full right aileron
         if fullLeft and fullRight and not xNeutral and self:stickNeutral() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("neutral_1")
            xNeutral = true
         end

         -- full up
         if not fullUp and not ((fullLeft or fullRight) and not xNeutral) and self:fullUp() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("fullUp")
            fullUp = true
         end

         -- full down
         if not fullDown and not ((fullLeft or fullRight) and not xNeutral) and self:fullDown() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("fullDown")
            fullDown = true
         end

         -- neutral after full up and full down
         if fullUp and fullDown and not yNeutral and self:stickNeutral() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("neutral_2")
            yNeutral = true
         end

         -- full left rudder
         if not fullLeftRud and xNeutral and yNeutral and self:fullLeftRud() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("fullLeft_2")
            fullLeftRud = true
         end

         -- full right rudder
         if not fullRightRud and xNeutral and yNeutral and self:fullRightRud() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("fullRight_2")
            fullRightRud = true
         end

         -- neutral after full left and full right rudder
         if fullLeftRud and fullRightRud and not rudNeutral and self:rudNeutral() then
            sleep(ECAM_delay)
            self.randomDelay()
            play("neutral_3")
            rudNeutral = true
         end

         if not fullLeft and not fullRight and not fullUp and not fullDown and not fullLeftRud and not fullRightRud then
            coroutine.yield()
         end

      until xNeutral and yNeutral and rudNeutral

      callouts.flightControlsChecked = true
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

setmetatable(callouts.flightControlsCheck,callouts.flightControlsCheck)

-- Main ---------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

callouts.firstRun = true
sleep(10000)
while true do callouts:main() end
