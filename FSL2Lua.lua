rootdir = lfs.currentdir():gsub("\\\\","\\") .. "\\Modules\\"
package.path = rootdir .. "FSL2Lua\\lib\\?.lua;" .. package.path

local FSL = require "FSL"
return FSL