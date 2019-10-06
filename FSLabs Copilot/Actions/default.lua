FSL2Lua_do_sequences = true
require "FSLabs Copilot"
local FSL = FSL
local usingVoice = voice_control == 1

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
   FSL:setTakeoffFlaps()
   repeat sleep() until not GSX_pushback()
   FSL.trimwheel:set()
end

function taxiSequence()
   if PM == 1 then FSL.PED_WXRadar_SYS_Switch("2")
   elseif PM == 2 then FSL.PED_WXRadar_SYS_Switch("1") end
   FSL.PED_WXRadar_PWS_Switch("AUTO")
   sleep(100)
   FSL.PED_WXRadar_PWS_Switch("AUTO")
   FSL.MIP_BRAKES_AUTOBRK_MAX_Button()
   FSL.PED_ECP_TO_CONFIG_Button()
   FSL.PED_ECP_TO_CONFIG_Button()
   FSL.PED_ECP_TO_CONFIG_Button()
end

function takeoffSequenceTrigger()
   return (thrustLeversSetForTakeoff() and FSL.OVHD_EXTLT_Land_L_Switch:getPosn() == "ON" and FSL.OVHD_EXTLT_Land_R_Switch:getPosn() == "ON")
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
      coroutine.yield()
   until count == 4
   return true
end

function lineUpSequence()
   local packs = FSL.atsuLog:getTakeoffPacks() or packs_on_takeoff
   FSL.PED_ATCXPDR_ON_OFF_Switch("ON")
   FSL.PED_ATCXPDR_MODE_Switch("TARA")
   if packs == 0 then
      if FSL.OVHD_AC_Pack_1_Button:isDown() then FSL.OVHD_AC_Pack_1_Button() end
      if FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() end
   end
end

function takeoffSequence()
   FSL.MIP_CHRONO_ELAPS_SEL_Switch("RUN")
   if after_landing == 1 then FSL.GSLD_Chrono_Button() end
end

function afterTakeoffSequence()
   if not FSL.OVHD_AC_Pack_1_Button:isDown() then FSL.OVHD_AC_Pack_1_Button() end
   sleep(plusminus(10000,0.2))
   if not FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() end
   repeat 
      sleep() 
      if onGround() then return end
   until readLvar("FSLA320_slat_l_1") == 0
   sleep(plusminus(2000,0.5))
   FSL.PED_SPD_BRK_LEVER("RET")
end

function tenThousandDepSequence()

   FSL.OVHD_EXTLT_Land_L_Switch("RETR")
   FSL.OVHD_EXTLT_Land_R_Switch("RETR")

   FSL.PED_MCDU_KEY_RADNAV()
   sleep(500)
   local VOR1 = FSL.MCDU:isBold(PM,49) or FSL.MCDU:isBold(PM,54)
   local VOR2 = FSL.MCDU:isBold(PM,71) or FSL.MCDU:isBold(PM,62)
   local ADF1 = FSL.MCDU:isBold(PM,241) or FSL.MCDU:isBold(PM,246)
   local ADF2 = FSL.MCDU:isBold(PM,263) or FSL.MCDU:isBold(PM,254)
   if VOR1 or VOR2 or ADF1 or ADF2 then 
      while not (FSL.MCDU:getScratchpad(PM):sub(6,8) == "CLR") do
         FSL.PED_MCDU_KEY_CLR()
         sleep(100)
      end
      local clr = true
      if VOR1 then
         if not clr then FSL.PED_MCDU_KEY_CLR() end
         FSL.PED_MCDU_LSK_L1()
         if clr then clr = false end
      end
      if VOR2 then
         if not clr then FSL.PED_MCDU_KEY_CLR() end
         FSL.PED_MCDU_LSK_R1() 
         if clr then clr = false end
      end
      if ADF1 then 
         if not clr then FSL.PED_MCDU_KEY_CLR() end
         FSL.PED_MCDU_LSK_L5() 
         if clr then clr = false end
      end
      if ADF2 then 
         if not clr then FSL.PED_MCDU_KEY_CLR() end
         FSL.PED_MCDU_LSK_R5()
      end
   end

   FSL.PED_MCDU_KEY_SEC()
   sleep(plusminus(1000))
   FSL.PED_MCDU_LSK_L1()

   sleep(plusminus(2000))

   FSL.PED_MCDU_KEY_FPLN()

   if not FSL.GSLD_EFIS_ARPT_Button:isLit() then FSL.GSLD_EFIS_ARPT_Button() end
   FSL.GSLD_EFIS_ND_Range_Knob("160")
   FSL.GSLD_EFIS_VORADF_1_Switch("VOR")
   FSL.GSLD_VORADF_2_Switch("VOR")

end

function tenThousandArrSequence()

   FSL.PED_MCDU_KEY_PERF()
   sleep(plusminus(500))
   while not FSL.MCDU:getString(PM,1,48):find("APPR") do
      FSL.PED_MCDU_LSK_R6()
      sleep(100)
   end
   local disp = FSL.MCDU:getString(PM,49,71)
   local LS = disp:find("ILS") or disp:find("LOC")

   FSL.OVHD_EXTLT_Land_L_Switch("ON")
   FSL.OVHD_EXTLT_Land_R_Switch("ON")
   FSL.OVHD_SIGNS_SeatBelts_Switch("ON")

   if not FSL.GSLD_EFIS_CSTR_Button:isLit() then FSL.GSLD_EFIS_CSTR_Button() end
   FSL.GSLD_EFIS_ND_Range_Knob("20")
   if LS and not FSL.GSLD_EFIS_LS_Button:isLit() then FSL.GSLD_EFIS_LS_Button() end

   FSL.PED_MCDU_KEY_RADNAV()
   sleep(plusminus(5000))
   FSL.PED_MCDU_KEY_PROG()

end

function afterLandingSequence(startApu)

   FSL.PED_FLAP_LEVER("0")
   FSL.PED_ATCXPDR_MODE_Switch("STBY")

   FSL.MIP_CHRONO_ELAPS_SEL_Switch("STP")
   if takeoff_sequence == 1 then FSL.GSLD_Chrono_Button() end

   FSL.OVHD_EXTLT_Strobe_Switch("AUTO")
   FSL.OVHD_EXTLT_RwyTurnoff_Switch("OFF")
   FSL.OVHD_EXTLT_Land_L_Switch("RETR")
   FSL.OVHD_EXTLT_Land_R_Switch("RETR")
   FSL.OVHD_EXTLT_Nose_Switch("TAXI")

   FSL.PED_WXRadar_SYS_Switch("OFF")
   FSL.PED_WXRadar_PWS_Switch("OFF")

   if not FSL.PF.GSLD_EFIS_FD_Button:isLit() and FDs_off_after_landing == 0 then
      FSL.PF.GSLD_EFIS_FD_Button()
   elseif FSL.PF.GSLD_EFIS_FD_Button:isLit() and FDs_off_after_landing == 1 then
      FSL.PF.GSLD_EFIS_FD_Button()
   end
   if FSL.PF.GSLD_EFIS_LS_Button:isLit() then FSL.PF.GSLD_EFIS_LS_Button() end
   if FSL.bird() then FSL.GSLD_FCU_HDGTRKVSFPA_Button() end
   if FSL.GSLD_EFIS_LS_Button:isLit() then FSL.GSLD_EFIS_LS_Button() end
   if not FSL.GSLD_EFIS_FD_Button:isLit() and FDs_off_after_landing == 0 then
      FSL.GSLD_EFIS_FD_Button()
   elseif FSL.GSLD_EFIS_FD_Button:isLit() and FDs_off_after_landing == 1 then
      FSL.GSLD_EFIS_FD_Button()
   end

   if pack2_off_after_landing == 1 and FSL.OVHD_AC_Pack_2_Button:isDown() then FSL.OVHD_AC_Pack_2_Button() end

   if ipc.get("afterLandingSequence") == 1 then FSL:startTheApu()
   else ipc.set("startApu",0) end

end

function init()
   ipc.set("lineupSequence",nil)
   ipc.set("takeoffSequence",nil)
   ipc.set("afterLandingSequence",nil)
   ipc.set("flyingCircuits",nil)
   ipc.set("startApu",nil)
end

function actions()

   if onGround() then

      if after_start == 1 and not enginesRunning() then
         waitForEnginesStarted()
         afterStartSequence()
      end

      if usingVoice then
         FSL.PED_MCDU_KEY_INIT()
         sleep(plusminus(1000))
         local disp = FSL.MCDU:getString(PM,64,72)
         local circuits = disp:sub(1,4) == disp:sub(6,9)
         if circuits then ipc.set("flyingCircuits",1) end
      end

      local co_lineup = coroutine.create(waitForLineup)
      local checksCompleted, taxiSeqCompleted
      while true do
         if during_taxi == 1 then
            checksCompleted = ipc.get("flightControlsChecked") and ipc.get("brakesChecked")
            if checksCompleted and not taxiSeqCompleted then
               sleep(plusminus(5000))
               taxiSequence()
               taxiSeqCompleted = true
            end
         end
         if lineup == 1 then
            if usingVoice then
               if not ipc.get("lineupSequence") then ipc.set("lineupSequence",0)
               elseif ipc.get("lineupSequence") == 1 then
                  sleep(plusminus(1000))
                  lineUpSequence()
                  ipc.set("lineupSequence",nil)
                  break
               end
            elseif not coroutine.resume(co_lineup) then
               lineUpSequence()
               break
            end
         end
         local eng1_N1 = ipc.readDBL(0x2010)
         local eng2_N1 = ipc.readDBL(0x2110)
         if eng1_N1 > 80 and eng2_N1 > 80 then break end
         sleep()
      end

      if takeoff_sequence == 1 and after_landing == 1 then
         if usingVoice then 
            ipc.set("takeoffSequence",0) 
            repeat sleep() until takeoffSequenceTrigger() or ipc.get("takeoffSequence") == 1 or not onGround()
         else repeat sleep() until takeoffSequenceTrigger() or not onGround() end
         sleep(plusminus(1000))
         if onGround() then takeoffSequence() end
         ipc.set("takeoffSequence",nil)
         local aborted
         repeat
            aborted = ipc.get("takeoffAborted")
            sleep() 
         until not onGround() or aborted
         if aborted then
            FSL.MIP_CHRONO_ELAPS_SEL_Switch("RST")
            if after_landing == 1 then FSL.GSLD_Chrono_Button() end
         end
      end

      if after_takeoff == 1 then
         repeat sleep() until not onGround() and FSL.getThrustLeversPos() == "CLB" 
         sleep(plusminus(2000))
         afterTakeoffSequence()
      end

   end

   if ten_thousand_dep == 1 then
      repeat sleep() until (climbing() and ALT() > 10200 and ALT() < 10300) or onGround()
      if not onGround() then tenThousandDepSequence() end
   end

   if ten_thousand_arr == 1 then
      repeat sleep() until (descending() and ALT() > 9500 and ALT() < 9700) or onGround()
      if not onGround() then tenThousandArrSequence() end
   end

   if after_landing == 1 then
      if usingVoice then
         repeat sleep() until onGround() and groundSpeed() < 30
         if after_landing_trigger == 1 then
            ipc.set("afterLandingSequence",0)
            repeat sleep() until ipc.get("afterLandingSequence") > 0 or not enginesRunning()
         elseif after_landing_trigger == 2 then
            ipc.set("afterLandingSequence",1)
            repeat sleep() until FSL.PED_SPD_BRK_LEVER:getPosn() ~= "ARM"
         end
         sleep(plusminus(1000))
         if enginesRunning() then afterLandingSequence() end
         ipc.set("afterLandingSequence",nil)
      else 
         repeat sleep() until (onGround() and groundSpeed() < 30 and FSL.PED_SPD_BRK_LEVER:getPosn() ~= "ARM") or not enginesRunning()
         sleep(plusminus(5000,0.5))
         if enginesRunning() then afterLandingSequence() end
      end
   end

   repeat sleep() until not enginesRunning()

   sleep(plusminus(30000))

   FSL.MIP_CHRONO_ELAPS_SEL_Switch("RST")

   if after_landing == 1 and takeoff_sequence == 1 then FSL.GSLD_Chrono_Button() end

end

while true do init() actions() end