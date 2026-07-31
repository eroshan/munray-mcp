-- Example: compass.ready()
local ok, err = compass.ready()
if err then
  error(err.message or tostring(err))
end
return ok
