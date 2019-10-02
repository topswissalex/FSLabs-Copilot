local rootdir = lfs.currentdir():gsub("\\\\","\\") .. "\\Modules\\"
package.path = rootdir .. "FSL2Lua\\lib\\?.lua;" .. package.path
return require "FSL"