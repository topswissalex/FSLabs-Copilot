-- ##################################################################
-- ############ EDIT USER OPTIONS HERE ##############################
-- ##################################################################

-- Callouts:

volume = 65
remote_port = 8080 -- The port of the remote MCDU. Only change it here if you changed it in the FSLabs options
play_V1 = 1 -- play V1 sound? 0 = no, 1 = yes
V1_timing = 0 -- V1 will be announced at the speed of V1 - V1_timing. If you want V1 to be announced slightly before V1 is reached on the PFD, type the number of knots.
PM = 2 -- Pilot Monitoring: 1 = Captain, 2 = First Officer
show_startup_message = 1 -- Show startup message? 0 = no, 1 = yes
sound_device = 0 -- zero is default (only change this if no sounds are played)
PM_announces_flightcontrol_check = 1 -- PM announces 'full left', 'full right' etc.
PM_announces_brake_check = 1 -- PM announces 'brake pressure zero' after the brake check. The trigger is the first application of the brakes after you start moving

-- Actions:

enable_actions = 1 -- allow the PM to perform the procedures that are listed below
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

rootdir = lfs.currentdir():gsub("\\\\","\\") .. "\\Modules\\"

FSL2Lua_pilot = PM
FSL2Lua_log = 1
FSL = require "FSL2Lua"

readLvar = ipc.readLvar
currTime = ipc.elapsedtime
sound_path = "..\\Modules\\FSLabs Copilot\\Sounds" 

-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

local logging = true
local logFile = rootdir .. "FSLabs Copilot\\FSLabs Copilot.log"
io.open(logFile,"w"):close()

function log(str,onlyMsg)
   if not logging then return end
   local file = io.open(logFile,"a")
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
   local prefix = "FSLabs Copilot: "
   if onlyMsg then timestamp = "" prefix = "" end
   ipc.log(prefix .. timestamp .. str)
   io.write(timestamp .. str .. "\n")
   io.close(file)
end

function sleep(time) ipc.sleep(time or 100) end
function pushback() return readLvar("FSLA320_NWS_Pin") == 1 end
function onGround() return ipc.readUB(0x0366) == 1 end
function groundSpeed() return ipc.readUD(0x02B4) / 65536 * 3600 / 1852 end
function ALT() return ipc.readUD(0x31E4) / 65536 end
function IAS() return ipc.readUW(0x02BC) / 128 end
function timePassedSince(ref) return currTime() - ref end
function reverseSelected() return readLvar("VC_PED_TL_1") > 100 and readLvar("VC_PED_TL_2") > 100 end

function thrustLeversSetForTakeoff()
   local TL_takeoffThreshold = 26
   local TL_reverseThreshold = 100
   local TL1, TL2 = readLvar("VC_PED_TL_1"), readLvar("VC_PED_TL_2")
   return TL1 < TL_reverseThreshold and TL1 >= TL_takeoffThreshold and TL2 < TL_reverseThreshold and TL2 >= TL_takeoffThreshold
end

function enginesRunning(both)
   local fuelFlow_1 = ipc.readDBL(0x2020)
   local fuelFlow_2 = ipc.readDBL(0x2120)
   local eng1_running = fuelFlow_1 > 0
   local eng2_running = fuelFlow_2 > 0
   if both then return eng1_running and eng2_running
   else return eng1_running or eng2_running end
end

function takeoffThrustIsSet()
   local eng1_N1 = ipc.readUW(0x0898) * 100 / 16384
   local eng2_N1 = ipc.readUW(0x0930) * 100 / 16384
   return eng1_N1 > 80 and eng2_N1 > 80
end

function getTakeoffSpeedsFromMCDU()
   FSL.PED_MCDU_KEY_PERF()
   sleep(500)
   local V1 = tonumber(FSL.MCDU.getDisplay(PM,49,51))
   local Vr = tonumber(FSL.MCDU.getDisplay(PM,97,99))
   sleep(1000)
   FSL.PED_MCDU_KEY_FPLN()
   if not V1 then log("V1 hasn't been entered") end
   if not Vr then log("Vr hasn't been entered") end
   return V1, Vr
end

local previousCalloutEndTime

function play(fileName,length)
   if previousCalloutEndTime and previousCalloutEndTime - currTime() > 0 then
      sleep(previousCalloutEndTime - currTime())
   end
   sound.play(fileName,sound_device,volume)
   if length then previousCalloutEndTime = currTime() + length
   else previousCalloutEndTime = nil end
end

-- Main ---------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

sound.path(sound_path)

if package.loaded["FSLabs Copilot"] then return end

if enable_actions == 1 then ipc.runlua("FSLabs Copilot\\SOP\\" .. SOP) end
ipc.runlua("FSLabs Copilot\\callouts")

do
   local play_V1 = play_V1
   local PM = PM
   if PM == 1 then PM = "Captain"
   else PM = "First Officer" end
   if play_V1 == 1 then play_V1 = "Yes"
   else play_V1 = "No" end
   log(">>>>>> Script started <<<<<<")
   log("Play V1 callout: " .. play_V1)
   log("Pilot Monitoring: " .. PM)
   log("----------------------------------------------------------------------------------------",1)
   log("----------------------------------------------------------------------------------------",1)
   local msg = "\n'Pilot Monitoring Callouts' plug-in started.\n\n\nSelected options:\n\nPlay V1 callout: " .. play_V1 .. "\n\nCallouts volume: " .. volume .. "%" .. "\n\nPilot Monitoring : " .. PM
   if show_startup_message == 1 then ipc.display(msg,20) sleep(20000) end
end
