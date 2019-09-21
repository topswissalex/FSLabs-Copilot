FSL2Lua_do_sequences = true
require "FSLabs Copilot"
local FSL, hand = FSL, hand

function waitForEnginesStarted()
   repeat
      local enginesStarted = enginesRunning() and FSL.PED_ENG_MODE_Switch:getPosn() == "NORM"
      if enginesStarted then
         sleep(4000)
         enginesStarted = enginesRunning() and FSL.PED_ENG_MODE_Switch:getPosn() == "NORM"
      end
      sleep()
   until enginesStarted
end

function afterStartSequence()
   FSL.PED_SPD_BRK_LEVER("ARM")
   FSL:setTakeoffFlaps() -- first checks the ATSU log. if nothing is there, checks the MCDU PERF page.
   repeat sleep() until not pushback() -- because GSX messes with setting the trim during pushback
   FSL.trimwheel:set() -- sets the trim using the final loadsheet MACTOW from the ATSU log
   hand:rest()
end

function waitForLineup()
   local startedCountingAtTime
   local count = 0
   repeat
      local switchPos = FSL.OVHD_SIGNS_SeatBelts_Switch:getVar()
      if prevSwitchPos and prevSwitchPos ~= switchPos then
         count = count + 1
         if count == 0 then startedCountingAtTime = currTime() end
      end
      if startedCountingAtTime and timePassedSince(startedCountingAtTime) > 2000 then
         count = 0
         startedCountingAtTime = nil
      end
      prevSwitchPos = switchPos
      sleep()
      if not onGround() then return false end
   until count == 4
   return true
end

function lineUpSequence()
   local packs = FSL.atsuLog:takeoffPacks() or packs_on_takeoff
   FSL.PED_ATCXPDR_ON_OFF_Switch("ON")
   FSL.PED_ATCXPDR_MODE_Switch("TARA")
   if packs == 0 then
      if FSL.OVHD_AC_Pack_1_Button:isDown() then FSL.OVHD_AC_Pack_1_Button() end
      if FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() end
   end
   hand:rest()
end

function waitForClbThrust() 
   repeat sleep() until not onGround() and FSL.getThrustLeversPos() == "CLB" 
end

function afterTakeoffSequence()
   if not FSL.OVHD_AC_Pack_1_Button:isDown() then FSL.OVHD_AC_Pack_1_Button() hand:rest() end
   sleep(plusminus(10000,0.2))
   if not FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() hand:rest() end
   repeat 
      sleep() 
      if onGround() then return end
   until readLvar("FSLA320_slat_l_1") == 0
   sleep(plusminus(2000,0.5))
   FSL.PED_SPD_BRK_LEVER("RET")
   hand:rest()
end

function waitForAfterLanding()
   repeat sleep() 
   until onGround() and groundSpeed() < 30 and FSL.PED_SPD_BRK_LEVER:getPosn() ~= "ARM"
end

function afterLandingCleanup()
   FSL.PED_FLAP_LEVER("0")
   FSL.PED_ATCXPDR_MODE_Switch("STBY")
   FSL.OVHD_EXTLT_Strobe_Switch("AUTO")
   FSL.OVHD_EXTLT_RwyTurnoff_Switch("OFF")
   FSL.OVHD_EXTLT_Land_L_Switch("RETR")
   FSL.OVHD_EXTLT_Land_R_Switch("RETR")
   FSL.OVHD_EXTLT_Nose_Switch("TAXI")
   FSL.PED_WXRadar_SYS_Switch("OFF")
   FSL.PED_WXRadar_PWS_Switch("OFF")
   if not FSL.PF.GSLD_EFIS_FD_Button:isLit() then FSL.PF.GSLD_EFIS_FD_Button() end
   if FSL.PF.GSLD_EFIS_LS_Button:isLit() then FSL.PF.GSLD_EFIS_LS_Button() end
   if FSL.bird() then FSL.GSLD_FCU_HDGTRKVSFPA_Button() end
   if FSL.GSLD_EFIS_LS_Button:isLit() then FSL.GSLD_EFIS_LS_Button() end
   if not FSL.GSLD_EFIS_FD_Button:isLit() then FSL.GSLD_EFIS_FD_Button() end
   if pack2_off_after_landing == 1 and FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() end
   FSL:startTheApu()
   hand:rest()
end

function main()

   if onGround() then

      if after_start == 1 then
         waitForEnginesStarted()
         afterStartSequence()
      end

      if lineup == 1 then
         local skip = not waitForLineup() 
         if not skip then
            sleep(plusminus(2000))
            if prob(0.2) then sleep(plusminus(2000)) end
            lineUpSequence() 
         end
      end

      if after_takeoff == 1 then
         waitForClbThrust()
         sleep(plusminus(2000))
         afterTakeoffSequence()
      end

   end

   if after_landing == 1 then
      waitForAfterLanding()
      sleep(plusminus(5000,0.5))
      afterLandingCleanup()
   end

   repeat sleep() until not enginesRunning()
end

---------------------------------------------------------------------------------------------------

-- To skip going through the ATSU loading process for the purposes of the testing, take an old ATSU
-- log, rename the file to 'test.log' and place it in the ATSU folder to use it as a dummy.
-- Then, open 'Modules/Lua/FSL.lua' and uncomment the commented out line in the 'FSL.getAtsuLog' function

-- There will be log messages in the console and in the log file in 'Modules/Lua/FSL' showing the
-- position of the current switch being interacted with, the timings, the speed and distance in detail.

---------------------------------------------------------------------------------------------------

-- Uncomment one sequence and/or its trigger function to test them separately

-- As an example, to test the after landing sequence and its trigger, you need to uncomment them,
-- set the controls from the sequence, accelerate above 30 kts GS, arm the speed brakes, and then
-- start the script.

---------------------------------------------------------------------------------------------------

-- waitForStartup()
-- afterStartSequence()



-- waitForLineup()
-- lineUpSequence()



-- waitForClbThrust()
-- afterTakeoffSequence()



-- waitForAfterLanding()
-- afterLandingCleanup()

-----------------------------------------------------------------------------------------

while true do main() end