-- "PMCO - Pilot Monitoring Callouts" FREEWARE LUA script
-- Version:
-- by Nils Unger, Peter Pukhnoy

-- ##################################################################
-- ############ EDIT USER OPTIONS HERE ##############################
-- ##################################################################

-- Callouts:

pV1 = 1 -- play V1 sound? 0 = no, 1 = yes
V1_timing = 0 --V1 will be announced at the speed of V1 - V1_timing. If you want V1 to be announced slightly before V1 is reached on the PFD, enter the number of kts.
PM = 2 -- Pilot Monitoring: 1 = Captain, 2 = First Officer
displayStartupMessage = 1 -- show script startup message 0 = no, 1 = yes
soundDevice = 0 -- zero is default (only change this, when no sound is played)
volume = 65 -- volume of all callouts (zero does NOT mean silenced, just rather quiet)
PM_announces_flightcontrol_check = 1 -- PM calls out 'full left', 'full right' etc.
PM_announces_brake_check = 1 -- PM calls out 'brake pressure zero' after your brake check. The trigger is the first application of the brakes after you start moving

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


-- Variables (NOT TO EDIT BY USER!!!) ---------------------------------------------------
-----------------------------------------------------------------------------------------

local sound_path = "..\\Modules\\PMCO_Sounds\\" -- path to the callout sounds
pilot = PM
local FSL = require("FSL")
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

function thrustLeversSetForTakeoff()
   local TL1, TL2 = ipc.readLvar("VC_PED_TL_1"), ipc.readLvar("VC_PED_TL_2")
   return TL1 < TL_reverseThreshold and TL1 >= TL_takeoffThreshold and TL2 < TL_reverseThreshold and TL2 >= TL_takeoffThreshold
end

function enginesRunning()
   local iEng1_N1 = ipc.readUW(0x0898) * 100 / 16384
   local iEng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   return iEng1_N1 > 15 and iEng2_N1 > 15
end

function thrustIsSet()
   local iEng1_N1 = ipc.readUW(0x0898) * 100 / 16384
   local iEng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   return iEng1_N1 > 80 and iEng2_N1 > 80
end

function announce(fileName, ECAM)

   local reactionTime = 750

   if ECAM then ipc.sleep(ECAM_delay + reactionTime) else ipc.sleep(PFD_delay) end

   repeat ipc.sleep(50) until not sound.query(previousCallout)

   previousCallout = sound.play(fileName,soundDevice,volume)

end

local callouts = {

   init = function(self)
      self.brakesChecked = false
      self.flightControlsChecked = false
      ipc.set("flightControlsChecked", nil)
      ipc.set("brakesChecked", nil)
   end,

   __call = function(self) -- main callouts logic

      self:init()
      repeat restingLoop() until enginesRunning()

      if onGround() then

         repeat

            local flightControlsCheck = coroutine.create(function() self:flightControlsCheck() end)
            local brakeCheck = coroutine.create(function() self:brakeCheck() end)
            repeat
               local flightControlsCheckedOrSkipped = self.flightControlsChecked or not coroutine.resume(flightControlsCheck)
               local brakesCheckedOrSkipped = self.brakesChecked or not coroutine.resume(brakeCheck)
            until flightControlsCheckedOrSkipped and brakesCheckedOrSkipped
            restingLoop() 

         until self:takeoff() or groundSpeed() > 70 or not enginesRunning() -- takeoff completed or aborted

         if not enginesRunning() then return end

      end

      repeat restingLoop() until onGround()

      self:landing() -- or aborted takeoff

   end,

   takeoffCancelled = function (self)
      local waitUntilCancel = 10000
      if not thrustLeversSetForTakeoff() then
         if groundSpeed() > 70 and (FSL.getThrustLeversPos == "IDLE" or FSL.getThrustLeversPos == "REV_IDLE" or FSL.getThrustLeversPos == "REV_MAX") then return true end
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
      local iV1Select = tonumber(FSL.MCDU.getDisplay(PM,49,51))
      local iVrSelect = tonumber(FSL.MCDU.getDisplay(PM,97,99))
      FSL.PED_MCDU_KEY_FPLN()
      if not iV1Select then log("V1 hasn't been entered") end
      if not iVrSelect then log("Vr hasn't been entered") end

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:thrustSet()

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:oneHundred()

      if pV1 == 1 then
         repeat
            if self:takeoffCancelled() then return false end
            criticalLoop()
         until self:V1()
      end

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:rotate()

      repeat
         if self:takeoffCancelled() then return false end
         criticalLoop()
      until self:positiveClimb()

      return true

   end,

   landing = function(self)
      repeat criticalLoop() until self:spoilers()
      repeat criticalLoop() until self:reverseGreen()
      repeat criticalLoop() until self:decel()
      repeat criticalLoop() until self:seventy()
   end,

   thrustSet = function(self)
      local bThrustSet, bSkipThis
      local iALT = ipc.readUD(0x31e4)/65536
      local iIAS = ipc.readUW(0x02bc)/128
      -- ipc.display("waiting for thrust set.\nIAS = " .. iIAS .. "\nALT = " .. iALT .. "\nEng1 N1 = " .. iEng1_N1 .."\nEng2 N1 = " .. iEng2_N1) -- debug
      if (iALT < 10.0) and thrustIsSet() then
         bThrustSet = true
         ipc.sleep(800) -- wait for further spool up
         announce("thrustSet") -- play "thrust set" callout
         log("thrust set")
      elseif (iIAS > 80.0) then  -- skip criterium
         bSkipThis = true
         log("thrust set skipped (IAS > 80 kts)")
      end
      return bThrustSet or bSkipThis
   end,

   oneHundred = function(self)
      local b100kts
      local iALT = ipc.readUD(0x31e4)/65536
      local iIAS = ipc.readUW(0x02bc)/128
      -- ipc.display("waiting for 100 kts.\nIAS = " .. iIAS .. "\nALT = " .. iALT) -- debug
      if (iALT < 10.0 and iIAS >= 100.0) then
         b100kts = true
         announce("100knots") -- play "100 kts" callout
         log("reached 100 kts")
      end
      return b100kts
   end,

   V1 = function(self)
      local bV1
      local iALT = ipc.readUD(0x31e4)/65536
      local iIAS = ipc.readUW(0x02bc)/128
      -- ipc.display("waiting for V1 = " .. sVrSelect .. "\nIAS = " .. iIAS .. "\nALT = " .. iALT) -- debug
      if (iALT < 10.0 and iIAS >= iV1Select) then
         bV1 = true
         announce("v1", 900) -- play "V1" callout
         log("reached V1")
      end
      return bV1
   end,

   rotate = function(self)
      local bVr
      local iALT = ipc.readUD(0x31e4)/65536
      local iIAS = ipc.readUW(0x02bc)/128
      -- ipc.display("waiting for Vr = " .. sVrSelect .. "\nIAS = " .. iIAS .. "\nALT = " .. iALT) -- debug
      if (iALT < 10.0 and iIAS >= iVrSelect) then
         bVr = true
         announce("rotate") -- play "Vr" callout
         log("reached Vr")
      end
   return bVr
   end,

   positiveClimb = function(self)
      local bPositiveClimb, bSkipThis
      local iALT = ipc.readUD(0x31e4)/65536
      local iVertSpeed = ipc.readSW(0x02c8)*60*3.28084/256
      -- ipc.display("waiting for positive rate of climb.\nALT = " .. iALT .. "\nV/S = " .. iVertSpeed) -- debug
      if (iALT >= 10.0 and iVertSpeed >= 500) then
         bPositiveClimb = true
         announce("positiveClimb") -- play "positive rate" callout
         log("reached positive climb")
      elseif (iALT > 150.0) then -- skip criterium: 150m / 500ft
         bSkipThis = true
         log("positive climb skipped (ALT > 500ft)")
      end
      return bPositiveClimb or bSkipThis
   end,

   spoilers = function(self)
      local bSpoilersDeployed, bSkipThis
      local iALT = ipc.readUD(0x31e4)/65536
      local iSpoiler_L_deployed = ipc.readLvar("FSLA320_spoiler_l_2") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_l_3") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_l_4") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_l_5") > spoilerThreshold
      local iSpoiler_R_deployed = ipc.readLvar("FSLA320_spoiler_r_2") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_r_3") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_r_4") > spoilerThreshold and ipc.readLvar("FSLA320_spoiler_r_5") > spoilerThreshold
      local iReverser_L = ipc.readLvar("FSLA320_reverser_left")
      local iReverser_R = ipc.readLvar("FSLA320_reverser_right")
      -- ipc.display("waiting for spoilers deployed.\nALT = " .. iALT .. "\nSpoiler L = " .. iSpoiler_L .."\nSpoiler R = " .. iSpoiler_R) -- debug
      if (iALT < 15.0) and iSpoiler_L_deployed and iSpoiler_L_deployed then
         bSpoilersDeployed = true
         log("spoilers deployed")
         announce("spoilers", 900, 1) -- play "spoilers" callout
      elseif ((groundSpeed() <= 100.0) or ((iReverser_L >= reverserDoorThreshold) and (iReverser_R >= reverserDoorThreshold))) then -- skip criterium
         bSkipThis = true
         log("skipped spoilers deployed")
      end
      return bSpoilersDeployed or bSkipThis
   end,

   reverseGreen = function(self)
      local bReversersActive, bSkipThis
      local iReverser_L = ipc.readLvar("FSLA320_reverser_left")
      local iReverser_R = ipc.readLvar("FSLA320_reverser_right")
      -- ipc.display("waiting for reversers to be active.\nReverser L = " .. iReverser_L .."\nReverser R = " .. iReverser_R) -- debug
      if ((iReverser_L >= reverserDoorThreshold) and (iReverser_R >= reverserDoorThreshold)) then
         bReversersActive = true
         log("detected reverse green")
         announce("reverseGreen",1) -- play "reverse green" callout
      elseif (groundSpeed() <= 90.0) then -- skip criterium
         bSkipThis = true
         log("skipped reverse green")
      end
      return bReversersActive or bSkipThis
   end,

   decel = function(self)
      local bDecel, bSkipThis
      local iAccelLateral = ipc.readDBL(0x3070)
      -- ipc.display("waiting for deceleration.\nLateral Acceleration = " .. iAccelLateral) -- debug
      if (iAccelLateral < -4.0) then
         bDecel = true
         log("detected deceleration")
         announce("decel",1) -- play "decel" callout
      elseif (groundSpeed() <= 80.0) then -- skip criterium
         bSkipThis = true
         log("not enough deceleration -> skipped callout")
      end
      return bDecel or bSkipThis
   end,

   seventy = function(self)
      local b70kts
      -- ipc.display("waiting for 70 kts.\nGS = " .. iGS) -- debug
      if (groundSpeed() <= 70.0) then
         b70kts = true
         announce("70knots") -- play "70 kts" callout
         log("reached 70 kts")
      end
      return b70kts
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

         if not pushback and groundSpeed() > 1 and leftBrakeApp > 0 and rightBrakeApp > 0 then
            ipc.sleep(500)
            if leftBrakeApp > 0 and rightBrakeApp > 0 and leftPressure == 0 and rightPressure == 0 then
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
         if not fullLeft and not (((fullLeftRud or fullRightRud) and not rudNeutral) or ((fullUp or fullDown) and not yNeutral)) and self:fullLeft() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullLeft1")
            fullLeft = true
         end

         -- full right aileron
         if not fullRight and not (((fullLeftRud or fullRightRud) and not rudNeutral) or ((fullUp or fullDown) and not yNeutral)) and self:fullRight() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullRight1")
            fullRight = true
         end

         -- full up
         if not fullUp and not (((fullLeftRud or fullRightRud) and not rudNeutral) or ((fullLeft or fullRight) and not xNeutral)) and self:fullUp() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullUp")
            fullUp = true
         end

         -- full down
         if not fullDown and not (((fullLeftRud or fullRightRud) and not rudNeutral) or ((fullLeft or fullRight) and not xNeutral)) and self:fullDown() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullDown")
            fullDown = true
         end

         -- full left rudder
         if not fullLeftRud and not (((fullLeft or fullRight) and not xNeutral) or ((fullUp or fullDown) and not yNeutral)) and self:fullLeftRud() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullLeft2")
            fullLeftRud = true
         end

         -- full right rudder
         if not fullRightRud and not (((fullLeft or fullRight) and not xNeutral) or ((fullUp or fullDown) and not yNeutral)) and self:fullRightRud() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("fullRight2")
            fullRightRud = true
         end

         -- neutral after full left and full right aileron
         if fullLeft and fullRight and not xNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("neutral1")
            xNeutral = true
         end

         -- neutral after full up and full down
         if fullUp and fullDown and not yNeutral and self:stickNeutral() then
            ipc.sleep(ECAM_delay)
            ipc.sleep(plusminus(300))
            announce("neutral2")
            yNeutral = true
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
   local pV1 = pV1
   local PM = PM
   if PM == 1 then
      PM = "Captain"
   else
      PM = "First Officer"
   end
   if pV1 == 1 then
      pV1 = "Yes"
   else
      pV1 = "No"
   end
   log(">>>>>> script started <<<<<<")
   log("user option 'Play V1 callout': " .. pV1)
   log("user option 'Pilot Monitoring': " .. PM)
   local msg = "\n'Pilot Monitoring Callouts' plug-in started.\n\n\nSelected options:\n\nPlay V1 callout: " .. pV1 .. "\n\nCallout volume: " .. volume .. "%" .. "\n\nPilot Monitoring : " .. PM
   if displayStartupMessage == 1 then ipc.display(msg,20) end
end

--running the callouts function in an infinite loop
while true do callouts() end
