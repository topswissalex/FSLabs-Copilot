FSL2Lua_do_sequences = true
require "FSLabs Copilot"
local FSL = FSL

local events = {
   BIRD_OFF = 1000,
   BIRD_ON = 1001,
   BRAKE_CHECK = 1002,
   CLEANUP = 1003,
   CLEANUP_NO_APU = 1004,
   CYLCE_FDS = 1005,
   EAI_OFF = 1006,
   EAI_ON = 1007,
   FDS_OFF = 1008,
   FDS_ON = 1009,
   FLAPS_1 = 1010,
   FLAPS_2 = 1011,
   FLAPS_3 = 1012,
   FLAPS_FULL = 1013,
   FLAPS_UP = 1014,
   GEAR_DN = 1015,
   GEAR_UP = 1016,
   LINEUP = 1017,
   SEAT_BELTS_OFF = 1018,
   START_APU = 1019,
   TAKEOFF = 1020,
   WAI_OFF = 1021,
   WAI_ON = 1022,
   FDS_OFF_BIRD_ON = 1023,
   SET_GA_ALT = 1024,
   NO_APU = 1025,
   TAXI_LIGHT_OFF = 1026,
   DISARM_DOORS = 1027
}

function flapsAfterTakeoffCondition()
   return (not ipc.get("descending") or ipc.get("flyingCircuits")) and not (FSL.getThrustLeversPos() == "FLX" or FSL.getThrustLeversPos() == "TOGA")
end

function flapsOnApproachCondition()
   return ipc.get("descending") or ipc.get("flyingCircuits")
end

function  react(plus)
   sleep(plusminus(500))
   if plus then sleep(plusminus(plus)) end
end

function voiceEvents(_,event)
   if event > 2000 or ipc.get("FSLC_mute") == 1 then return end
   for k,v in pairs(events) do if event == v then print(k) end end
   if event == events.GEAR_UP and ipc.get("takeoffAtTime") and currTime() - ipc.get("takeoffAtTime") < 60000 then
      react()
      FSL.MIP_GEAR_Lever("UP")
   elseif event == events.GEAR_DN and flapsOnApproachCondition() then
      react()
      FSL.MIP_GEAR_Lever("DN")
      FSL.PED_SPD_BRK_LEVER("ARM")
   elseif event == events.FLAPS_1 and not onGround() then
      if FSL.PED_FLAP_LEVER:getPosn() == "0" and flapsOnApproachCondition() then
         react(500)
         play("flapsOne")
         FSL.PED_FLAP_LEVER("1")
      elseif FSL.PED_FLAP_LEVER:getPosn() == "2" and flapsAfterTakeoffCondition() then
         react(500)
         play("flapsOne")
         FSL.PED_FLAP_LEVER("1")
      end
   elseif event == events.FLAPS_2 and not onGround() then
      if FSL.PED_FLAP_LEVER:getPosn() == "3" and flapsAfterTakeoffCondition() then
         react(500)
         play("flapsTwo")
         FSL.PED_FLAP_LEVER("2")
      elseif FSL.PED_FLAP_LEVER:getPosn() == "1" and flapsOnApproachCondition() then
         react(500)
         play("flapsTwo")
         FSL.PED_FLAP_LEVER("2")
      end
   elseif event == events.FLAPS_3 and not onGround() and FSL.PED_FLAP_LEVER:getPosn() == "2" and flapsOnApproachCondition() then
      react(500)
      play("flapsThree")
      FSL.PED_FLAP_LEVER("3")
   elseif event == events.FLAPS_FULL and not onGround() and FSL.PED_FLAP_LEVER:getPosn() == "3" and flapsOnApproachCondition() then
      react(500)
      play("flapsFull")
      FSL.PED_FLAP_LEVER("FULL")
   elseif event == events.FLAPS_UP and not onGround() and FSL.PED_FLAP_LEVER:getPosn() == "1" and flapsAfterTakeoffCondition() then
      react(500)
      play("flapsUp")
      FSL.PED_FLAP_LEVER("0")
   elseif event == events.CLEANUP and ipc.get("afterLandingSequence") == 0 then ipc.set("afterLandingSequence",1)
   elseif event == events.CLEANUP_NO_APU and ipc.get("afterLandingSequence") == 0 then ipc.set("afterLandingSequence",2)
   elseif event == events.NO_APU and ipc.get("afterLandingSequence") == 1 then ipc.set("afterLandingSequence",2)
   elseif event == events.LINEUP and ipc.get("lineupSequence") == 0 then ipc.set("lineupSequence",1)
   elseif event == events.BRAKE_CHECK and ipc.get("brakeCheckVoiceTrigger") == 0 then ipc.set("brakeCheckVoiceTrigger",1)
   elseif event == events.TAKEOFF and ipc.get("takeoffSequence") == 0 then ipc.set("takeoffSequence",1)
   elseif event == events.START_APU then 
      if ipc.get("startApu") == 0 then
         sleep(plusminus(1000))
         FSL:startTheApu() 
         ipc.set("startApu",nil)
      elseif ipc.get("afterLandingSequence") == 2 then
         ipc.set("afterLandingSequence",1)
      end
   elseif event == events.TAXI_LIGHT_OFF and ipc.get("landedAtTime") and groundSpeed() < 30 then
      FSL.OVHD_EXTLT_Nose_Switch("OFF")
   end
end

event.control(66587,"voiceEvents")