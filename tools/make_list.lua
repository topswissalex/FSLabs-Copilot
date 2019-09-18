package.path = lfs.currentdir():gsub("\\\\","\\") .. "\\Modules\\Lua_FSL_lib\\?.lua;" .. package.path
local FSL = require "FSL"

local name = "List_of_Functions.txt"
io.open(name,"w"):close()
local file = io.open(name,"a")
io.input(file)
io.output(file)

io.write("If the control is a button, call its function without arguments\n")
io.write("If the control has positions, call its function with the position as the argument\n")

function makeList(table,tableName)
   for controlName,controlObj in pairs(table) do
      local line
      if type(controlObj) == "table" and controlName then
         if (controlObj.inc and controlObj.dec) or controlObj.tgl then
            line = tableName .. "." .. controlName ..
            repeat
               line = line .. " "
            until #line == 42
         end
         if controlObj.posn then
            line = line .. "Positions: "
            for pos in pairs(controlObj.posn) do
               if pos == pos:upper() then line = line .. "\"" .. pos:upper() .. "\", " end
            end
            if line:sub(#line-1,#line-1) == "," then line = line:sub(1, #line-2) end
         end
      elseif type(controlObj) == "function" then line = tableName .. "." .. controlName .. end
      if line then io.write(line .. "\n") end
   end
end

makeList(FSL,"FSL")
makeList(FSL.FO, "FSL.FO")
makeList(FSL.CPT, "FSL.CPT")
makeList(FSL.MCDU, "FSL.MCDU")
makeList(FSL.atsuLog, "FSL.atsuLog")