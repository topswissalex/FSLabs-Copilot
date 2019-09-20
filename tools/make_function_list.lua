local FSL = require "FSL2Lua"

local name = "List of controls.txt"
io.open(name,"w"):close()
local file = io.open(name,"a")
io.input(file)
io.output(file)

function pairsByKeys (t, f)
   local a = {}
   for n in pairs(t) do table.insert(a, n) end
   table.sort(a, f)
   local i = 0      -- iterator variable
   local iter = function ()   -- iterator function
      i = i + 1
      if a[i] == nil then return nil
      else return a[i], t[a[i]]
      end
   end
   return iter
end

function makeList(table,tableName)
   local temp = {}
   for controlName,controlObj in pairs(table) do
      local line
      if type(controlObj) == "table" and controlName then
         if (controlObj.inc and controlObj.dec) or controlObj.tgl then
            line = tableName .. "." .. controlName
            repeat
               line = line .. " "
            until #line == 42
         end
         if controlObj.posn then
            line = line .. "Positions: "
            for pos in pairsByKeys(controlObj.posn) do
               if pos == pos:upper() then line = line .. "\"" .. pos:upper() .. "\", " end
            end
            if line:sub(#line-1,#line-1) == "," then line = line:sub(1, #line-2) end
         end
      elseif type(controlObj) == "function" then line = tableName .. "." .. controlName end
      if line then temp[line] = "" end
   end
   for line in pairsByKeys(temp) do
      io.write("---------------------------------------------------------------------------------------------------------\n\n")
      io.write(line .. "\n\n")
   end
end

makeList(FSL,"FSL")
makeList(FSL.FO, "FSL.FO")
makeList(FSL.CPT, "FSL.CPT")