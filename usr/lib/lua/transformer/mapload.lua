local find, format, byte, match = string.find, string.format, string.byte, string.match
local require, type, error, loadfile, setfenv, getfenv, setmetatable, pcall =
      require, type, error, loadfile, setfenv, getfenv, setmetatable, pcall
local pairs, ipairs, tostring, rawset =
      pairs, ipairs, tostring, rawset
local lfs = require("lfs")
local insert = table.insert
local logger = require("transformer.logger")
local maphelper = require 'transformer.maphelper'
local xref = require 'transformer.xref'
local xpcall = require ("tch.xpcall")
local traceback = debug.traceback

local function get_empty()
  return ''
end

local function hidden_mapping(mapping)
  local objtype = mapping.objectType
  local result
  for pname, ptype in pairs(objtype.parameters) do
    if ptype.hidden then
      if not result then
        result = {}
      end
      insert(result,pname)
    end
  end
  if result and #result > 0 then
    maphelper.wrap_get(mapping)
    for _, pname in pairs(result) do
      mapping.get[pname] = get_empty
    end
  end
end

-- check a whole bunch of properties of a mapping and throw an
-- error if we find something wrong with it
local function validate_mapping(mapping)
  local objtype = mapping.objectType
  if type(objtype) ~= "table" then
    error("no objectType defined", 3)
  end
  local name = objtype.name
  if type(name) ~= "string" then
    error("objectType.name not a string", 3)
  end
  -- checking if objtype name ends in a dot
  -- note: we're assuming ASCII (46 is decimal value of the dot in ASCII)
  if byte(objtype.name, #objtype.name) ~= 46 then
    error(format("'%s' doesn't end with a dot", name), 3)
  end
  if type(objtype.parameters) ~= "table" then
    error(format("'%s': no 'parameters' table", name), 3)
  end
  if type(objtype.maxEntries) ~= "number" then
    error(format("'%s': '%s' not a %s", name, "maxEntries", "number"), 3)
  end
  if type(objtype.minEntries) ~= "number" then
    error(format("'%s': '%s' not a %s", name, "minEntries", "number"), 3)
  end
  -- possible values for minEntries and maxEntries:
  --  min = 0, max = 1 --> optional SI --> not yet supported
  --  min = 0 or min = 1, max > 0 --> MI
  --  min = 1, max = 1 --> SI
  --  all the rest is not valid/supported
  if objtype.minEntries == 0 then
    if objtype.maxEntries == 1 then
      error(format("'%s': optional single instance not supported", name), 3)
    end
    if objtype.maxEntries < 0 then
      error(format("'%s': %s must be > 0", name, "maxEntries"), 3)
    end
    -- MI objtypes must have an 'entries' function and their name must end in ".{i}." or ".{@}."
    if type(mapping.entries) ~= "function" then
      error(format("'%s': %s > 1 but no 'entries' function defined", name, "maxEntries"), 3)
    end
    if not find(name, "%.{i}%.$") and not find(name, "%.@%.$") then
      error(format("'%s' is multi instance but doesn't end with '.{i}.' or '.@.'", name), 3)
    end
  elseif objtype.minEntries == 1 then
    if objtype.maxEntries < 1 then
      error(format("'%s': if %s == 1 then %s must be >= 1", name, "minEntries", "maxEntries"), 3)
    end
  else
    error(format("'%s': invalid combination of %s en %s", name, "minEntries", "maxEntries"), 3)
  end
  if objtype.access == "readWrite" then
    if objtype.maxEntries == 1 then
      error(format("'%s': readWrite objects should have %s > 1", name, "maxEntries"), 3)
    end
    if type(mapping.add) ~= "function" then
      error(format("'%s:' no '%s' function", name, "add"), 3)
    end
    if type(mapping.delete) ~= "function" then
      error(format("'%s:' no '%s' function", name, "delete"), 3)
    end
  else
    if objtype.access ~= "readOnly" then
      error(format("'%s%s': 'access' should be 'readOnly' or 'readWrite'", name, ""), 3)
    end
  end
  for pname, ptype in pairs(objtype.parameters) do
    if type(pname) ~= "string" then
      error(format("'%s': parameter table is invalid", name), 3)
    end
    if type(ptype) ~= "table" then
      error(format("'%s': '%s' not a %s", name, pname, "table"), 3)
    end
    if type(ptype.type) ~= "string" then
      error(format("'%s%s': '%s' not a %s", name, pname, "type", "string"), 3)
    end
    if ptype.access == "readWrite" then
      local set = mapping.set
      local type_set = type(set)
      if type_set ~= "function" and
         (type_set ~= "table" or type(set[pname]) ~= "function") then
        error(format("'%s%s': no setter", name, pname), 3)
      end
    elseif ptype.access ~= "readOnly" then
      error(format("'%s%s': 'access' should be 'readOnly' or 'readWrite'", name, pname), 3)
    end
    local type_default = type(ptype.default)
    if type_default ~= "nil" and type_default ~= "string" then
      error(format("'%s%s': '%s' not a %s", name, pname, "default", "string"), 3)
    end
    local get = mapping.get
    local type_get = type(get)
    if type_get ~= "function" and
       (type_get ~= "table" or (type(get[pname]) ~= "function"
         and type(get[pname]) ~= "string")) then
      error(format("'%s%s': no getter", name, pname), 3)
    end
  end
  local getall = mapping.getall
  if getall and type(getall)~='function' then
    error(format("getall for %s must be a function if supplied", name), 3)
  end
end

-- check if all fields of 't' are also in 'u'
local function is_subset(t, u)
  for k, v in pairs(t) do
    if u[k] ~= v then
      return false
    end
  end
  return true
end

-- Count the number of fields in table 't'
local function get_count(t)
  local count = 0
  for _,_ in pairs(t) do
    count = count + 1
  end
  return count
end

-- Metatable for the paramtype_cache. If a lookup occurs of an unknown
-- key, we create a new weak table and return it.
local mt = {}

mt.__index = function(t,key)
  local v = setmetatable({}, {__mode = "v"})
  rawset(t,key,v)
  return v
end

-- Cache of all paramtypes so we can easily iterate over them to
-- check if a new paramtype is the same as one in the cache. The cache
-- contains sub-tables for every size of paramtype it encounters.
-- This cache has weak sub-tables to prevent the cache keeping
-- paramtypes alive when no mappings still refer to it.
local paramtype_cache = setmetatable({}, mt)

local function memoize_paramtype(paramtype)
  local count = get_count(paramtype)
  local cache = paramtype_cache[count]
  for _, cached in pairs(cache) do
    if is_subset(cached, paramtype) then
      return cached
    end
  end
  cache[#cache + 1] = paramtype
  return paramtype
end

--- A special function which will memoize the parametertype definitions
-- These are notoriously repetitive, this halves the memory used for parametertypes.
local function memoize_paramtypes(mapping)
  local paramtypes = mapping.parameters

  for name, paramtype in pairs(paramtypes) do
    paramtypes[name] = memoize_paramtype(paramtype)
  end
end

local function create_map_env(store, commitapply)
  -- The environment available to a mapping.
  -- All these functions can throw an error.
  local function register(mapping)
    validate_mapping(mapping)
    hidden_mapping(mapping)
    memoize_paramtypes(mapping.objectType)
    store:add_mapping(mapping)
  end
  local map_env = {
    commitapply = commitapply,
    register = register,
    resolve = function(typepath, key)
        return xref.resolve(store, typepath, key)
    end,
    tokey = function(objectpath, ...)
        return xref.tokey(store, objectpath, ...)
    end,
    mapper = function(name)
      local mapper = require("transformer.mapper." .. name)
      -- When a function of the mapper is called we want to access
      -- the commitapply context in that function. To be able to do
      -- that the mapper function must have the environment that is
      -- used on the mapping file chunk.
      local fenv = getfenv(2)
      for _, f in pairs(mapper) do
        if type(f) == "function" then
          setfenv(f, fenv)
        end
      end
      return mapper
    end,
    eventsource = function(name)
      local evsrc = require("transformer.eventsource." .. name)
      evsrc.set_store(store)
      return evsrc
    end,
    query_keys = function(mapping, level)
      return store.persistency:query_keys(mapping.objectType.name, level)
    end
  }
  -- in your map you can access everything but you're
  -- not allowed to create new global variables
  setmetatable(map_env, {
    __index = _G,
    __newindex = function()
        error("global variables are evil", 2)
    end
  })
  return map_env
end

-- Load the map pointed to by 'file' using the provided environment.
local function load_map(map_env, file)
  local mapping, errmsg = loadfile(file)
  if not mapping then
    -- file not found or syntax error in map
    return nil, errmsg
  end
  setfenv(mapping, map_env)
  local rc, errormsg = pcall(mapping)
  if not rc then
    -- map didn't load; probably because it didn't validate
    return nil, errormsg
  end
  logger:info("loaded %s", file)
  return true
end

-- the mapping get function for a numEntries parameter
local function get_child_count(mapping, paramname, ...)
    local numEntries = mapping['@@_numEntries']
    local child = numEntries[paramname]
    if child then
        local rc, entries, errmsg = xpcall(child.entries, traceback, child, ...)
        if not rc then
            logger:error("entries() threw an error : %s", entries)
        elseif not entries then
            logger:error("entries() failed: %s", errmsg or "<no error msg>")
        else
            return tostring(#entries)
        end
    else
        logger:warning("no entries for %s.%s", mapping.objectType.name, paramname)
    end
    return '0'
end

-- fixup the NumberOfEntries parameters
-- loop over all mapping and add their numEntriesParameter (if any) to their
-- parent.
local function fixupNumberOfEntries(store)
    local numEntriesType = memoize_paramtype{
        access = "readOnly"; 
        type = "unsignedInt";
        single = true; --to prevent getting it through getall
    }
    for _, mapping in ipairs(store.mappings) do
        local pne = mapping.objectType.numEntriesParameter
        if pne then
            -- there is a numEntriesParameter
            -- get the parent 
            local parent = store:parent(mapping)
            if parent then
                -- make sure the parameter exists
                if not parent.objectType.parameters[pne] then
                    parent.objectType.parameters[pne] = numEntriesType 
                end
                -- add it to the list of numEntries parameters in the parent
                -- this info is used in the getter function
                local numEntries = parent['@@_numEntries']
                if not numEntries then
                    numEntries = {}
                    parent['@@_numEntries'] = numEntries
                end
                numEntries[pne] = mapping

                maphelper.wrap_get(parent)
                parent.get[pne] = get_child_count
            end
        end
    end
end

-- Load all the maps on the specified path recursively and store them in
-- the provided map environment.
local function load_maps_recursively(map_env, mappath)
  -- if 'mappath' points to a file then load that file
  if lfs.attributes(mappath, 'mode') == 'file' then
    -- only consider files with the '.map' extension
    if find(mappath, "%.map$") then
      local rc, errormsg = load_map(map_env, mappath)
      -- currently we just ignore maps that fail to load
      if not rc then
        logger:error("%s ignored (%s)", mappath, errormsg)
      end
    end
  -- if 'mappath' points to a directory load it recursively
  elseif lfs.attributes(mappath, 'mode') == 'directory' then
    for file in lfs.dir(mappath) do
      if file ~= "." and file ~= ".." then
        load_maps_recursively(map_env, mappath.."/"..file)
      end
    end
  end
end

local M = {}

-- Load all the maps in 'mappath' and store them in 'store'.
-- @param store The typestore in which to add loaded mappings.
-- @param commitapply The commit & apply context to use in your mappings or
--                    mappers. See the commit & apply documentation.
-- @param mappath The location where to read the maps from. It can be one file
--          or a directory with map files. In the latter case it will only
--          load files ending with ".map".
-- @return 'true' if all went well and nil + error message otherwise
function M.load_all_maps(store, commitapply, mappath)
  local map_env = create_map_env(store, commitapply)
  -- a single mapping file is provided
  if lfs.attributes(mappath, 'mode') == 'file' then
    local rc, errmsg = load_map(map_env, mappath)
    if not rc then
      return nil, errmsg
    end
  -- a directory with mapping files is provided
  else
    load_maps_recursively(map_env, mappath)
  end
  fixupNumberOfEntries(store)
  return true
end

return M
