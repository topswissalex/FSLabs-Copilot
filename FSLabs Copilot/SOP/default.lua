local FSL = FSL
local hand = FSL.hand

function waitForStartup()
   local engines_started
   repeat
      local Eng1_N1 = ipc.readUW(0x0898) * 100 / 16384
      local Eng2_N1 = ipc.readUW(0x0930) * 100 / 16384
      if (Eng1_N1 > 15 or Eng2_N1 > 15) and FSL.PED_ENG_MODE_Switch:getPosn() == "NORM" then
         ipc.sleep(4000)
         engines_started = (Eng1_N1 > 15 or Eng2_N1 > 15) and FSL.PED_ENG_MODE_Switch:getPosn() == "NORM"
      end
      ipc.sleep(1000)
   until engines_started
end

function afterStartSequence()
   FSL.PED_SPD_BRK_LEVER("ARM")
   FSL.setTakeoffFlaps() -- first checks the ATSU log. if nothing is there, checks the MCDU PERF page.
   repeat ipc.sleep(100) until ipc.readLvar("FSLA320_NWS_Pin") == 0 -- because GSX messes with setting the trim during pushback
   FSL.trimwheel:set() -- sets the trim using the final loadsheet MACTOW from the ATSU log
   hand:rest()
end

function waitForLineup()
   local startedCountingAtTime, count
   repeat
      local switchPos = FSL.OVHD_SIGNS_SeatBelts_Switch:getVar()
      if prevSwitchPos and prevSwitchPos ~= switchPos then
         if not count then 
            count = 0
            startedCountingAtTime = ipc.elapsedtime()
          end
         count = count + 1
      end
      if startedCountingAtTime and ipc.elapsedtime() - startedCountingAtTime > 2000 then
         count = false
      end
      prevSwitchPos = switchPos
      ipc.sleep(100)
      if ipc.readUB(0x0366) == 1 then return true end
   until count == 4
   ipc.sleep(plusminus(2000))
   if prob(0.2) then ipc.sleep(plusminus(2000)) end
end

function lineUpSequence()
   local packs = FSL.getTakeoffPacksFromAtsuLog() or packs_ON_takeoff
   FSL.PED_ATCXPDR_MODE_Switch("TARA")
   if packs == 0 then
      if FSL.OVHD_AC_Pack_1_Button:isDown() then FSL.OVHD_AC_Pack_1_Button() end
      if FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() end
   end
   hand:rest()
end

function waitForTakeoff()
   repeat ipc.sleep(100) until ipc.readLvar("VC_PED_TL_1") > 26 and ipc.readLvar("VC_PED_TL_2") > 26
   ipc.sleep(3000)
   if ipc.readLvar("VC_PED_TL_1") > 26 and ipc.readLvar("VC_PED_TL_2") > 26 then
      return
   else waitForTakeoff()
   end
end

function takeoffSequence()
   
end

function waitForClbThrust()
   repeat ipc.sleep(1000) until ipc.readUB(0x0366) == 0
   repeat ipc.sleep(1000) until FSL.getThrustLeversPos(1) == "CLB" and FSL.getThrustLeversPos(2) == "CLB"
   ipc.sleep(plusminus(2000))
end

function afterTakeoffSequence()
   if not FSL.OVHD_AC_Pack_1_Button:isDown() then FSL.OVHD_AC_Pack_1_Button() hand:rest() end
   ipc.sleep(plusminus(10000,0.2))
   if not FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() hand:rest() end
   repeat ipc.sleep(100) until ipc.readLvar("FSLA320_slat_l_1") == 0
   ipc.sleep(plusminus(2000,0.5))
   FSL.PED_SPD_BRK_LEVER("RET")
   hand:rest()
end

function waitForAfterLanding()
   repeat
      ipc.sleep(1000)
      local on_ground = ipc.readUB(0x0366) == 1
      local GS = ipc.readUD(0x02b4) / 65536 * 3600 / 1852
   until on_ground and GS < 30 and FSL.PED_SPD_BRK_LEVER:getPosn() ~= "ARM"
   ipc.sleep(plusminus(5000,0.5))
end

function afterLandingCleanup()
   FSL.PED_FLAP_LEVER("0")
   FSL.PED_ATCXPDR_MODE_Switch("STBY")
   FSL.OVHD_EXTLT_Strobe_Switch("OFF")
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
   FSL.startTheApu()
   hand:rest()
end

function main()
   if after_start == 1 then
      waitForStartup()
      afterStartSequence()
   end
   if lineup == 1 then
      local skip = waitForLineup() 
      if not skip then lineUpSequence() end
   end
   if after_takeoff == 1 then
      waitForClbThrust()
      afterTakeoffSequence()
   end
   if after_landing == 1 then
      waitForAfterLanding()
      afterLandingCleanup()
   end
end

---------------------------------------------------------------------------------------------------

-- To skip going through the ATSU loading process for the purposes of the testing, take an old ATSU
-- log, rename the file to 'test.log' and place it in the ATSU folder to use it as a dummy.
-- Then, open 'Modules/Lua/FSL.lua' and uncomment the commented out line in the 'FSL.getAtsuLog' function

-- There will be log messages in the console and in the log file in 'Modules/Lua/FSL' showing the
-- position of the current switch being interacted with, the timings, the speed and distance in detail.

---------------------------------------------------------------------------------------------------

-- Uncomment to test the complete flow:

--main()

---------------------------------------------------------------------------------------------------

-- Uncomment one sequence and/or its trigger function to test them separately

-- As an example, to test the after landing sequence and its trigger, you need to uncomment them,
-- set the controls from the sequence, accelerate above 30 kts GS, arm the speed brakes, and then
-- start the script.

---------------------------------------------------------------------------------------------------

--waitForStartup()
--afterStartSequence()



--waitForLineup()
--lineUpSequence()



--waitForClbThrust()
--afterTakeoffSequence()



--waitForAfterLanding()
--afterLandingCleanup()


---------------------------------------------------------------------------------------------------

while true do
   main()
   repeat
      ipc.sleep(5000)
      local Eng1_N1 = ipc.readUW(0x0898) * 100 / 16384
      local Eng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   until Eng1_N1 < 5 and Eng2_N1 < 5
end