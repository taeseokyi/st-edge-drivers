--[[
  Copyright 2021 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  Web requests: execute web requests via mobile app or device command; supports http and https


  Modified by Taeseok Yi, 2026: dashboard-specific profiles (none/string/number/dKH), keynumvalue + temperatureMeasurement events,
  profiles v2h (2026-11-02): dashboard modes are explicit - plain number (keynumvalue only, no temperature),
  temperature (keynumvalue + temperatureMeasurement for the app graph), dKH (dkhvalue + CO2 graph);
  detail views show only the value row for the mode (raw string/numeric rows hidden where redundant);
  dKH (carbonate hardness) dashboard mode with 3-decimal display, periodic auto-refresh timer.
  v1.5: device profile is chosen from the dashboard preference at init (previously init forced the
  number profile, undoing a dKH/none/string choice on every driver restart), so devices migrated from
  another driver land on this driver's own profile; device_removed timer cancel fixed.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                 -- just for time
local socket = require "cosock.socket"          -- just for time
local http = cosock.asyncify "socket.http"
local https = cosock.asyncify "ssl.https"
http.TIMEOUT = 3
https.TIMEOUT = 3
local ltn12 = require "ltn12"
local log = require "log"

-- Driver modules
local parser = require "parsekey"



-- Module variables
local webreqDriver
local initialized = false
local devcounter = 1
local webreq_commands = {}

local BODYDELIM = '{{^}}'
local NUMBER_DEVICEPROFILE = 'webrequestm_dashnum.v2f'
local NUMBER_DEVICEADDLPROFILE = 'webrequestm_addl_dashnum.v2f'

-- Profile for a device, from its dashboard preference and whether it is a master
-- (master = has the 'create another device' capability). Used at init, so a device
-- that came over from another driver, or whose profile is out of date, is put on this
-- driver's own profile; and when the dashboard preference changes.
local PROFILE_BY_DASHBOARD = {
  none          = { master = 'webrequestm_dashnone.v2h',  addl = 'webrequestm_addl_dashnone.v2h' },
  extractstring = { master = 'webrequestm_dashstr.v2h',   addl = 'webrequestm_addl_dashstr.v2h'  },
  extractnum    = { master = 'webrequestm_dashnum.v2h',   addl = 'webrequestm_addl_dashnum.v2h'  },  -- plain number
  extracttemp   = { master = 'webrequestm_dashtemp.v2h',  addl = 'webrequestm_addl_dashtemp.v2h' },  -- temperature + graph
  extractdkh    = { master = 'webrequestm_dashdkh.v2h',   addl = 'webrequestm_addl_dashdkh.v2h'  },  -- dKH + CO2 graph
}

local function is_master(device)
  return device:supports_capability_by_id('partyvoice23922.createanother')
end

local function profile_for(device)
  local entry = PROFILE_BY_DASHBOARD[device.preferences.dashboard] or PROFILE_BY_DASHBOARD.extractnum
  if is_master(device) then
    return entry.master
  end
  return entry.addl
end

-- Custom capabilities
local cap_select = capabilities["partyvoice23922.webrequestselect"]
local cap_requestcmd = capabilities["partyvoice23922.webrequest"]
local cap_apireqcmd = capabilities["partyvoice23922.apiwebrequest"]
local cap_httpcode = capabilities["partyvoice23922.httpcode"]
local cap_response = capabilities["partyvoice23922.httpresponse"]
local cap_keyvalue = capabilities["partyvoice23922.keyvalue2"]
local cap_keynumvalue = capabilities["partyvoice23922.keynumvalue"]
local cap_dkhvalue = capabilities["cleverflower44023.dkhvalue"]
local cap_createdev = capabilities["partyvoice23922.createanother"]


local function validate_address(lanAddress)

  local valid = true
  
  local ip = lanAddress:match('^(%d.+):')
  local port = tonumber(lanAddress:match(':(%d+)$'))
  
  if ip then
    local chunks = {ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
    if #chunks == 4 then
      for _, v in pairs(chunks) do
        if tonumber(v) > 255 then 
          valid = false
          break
        end
      end
    else
      valid = false
    end
  else
    valid = false
  end
  
  if port then
    if type(port) == 'number' then
      if (port < 1) or (port > 65535) then 
        valid = false
      end
    else
      valid = false
    end
  else
    valid = false
  end
  
  if valid then
    return ip, port
  else
    return nil
  end
      
end

-- Validate provided http request string
local function validate(input, silent)

  local msg
  local method = string.upper(input:match('(%a+):'))
  local url = input:match(':(.+)')
  
  if (method == 'GET') or (method == 'POST') or (method == 'PUT') then

    local protocol = url:match('^(%a+):')
    if (protocol == 'http') or (protocol == 'https') then
    
      local skiplen
      if protocol == 'http' then; skiplen = 8; end
      if protocol == 'https' then; skiplen = 9; end
      
      local startpath = url:find('/', skiplen+1)
      local urladdr
      
      if startpath ~= nil then
        urladdr = url:sub(skiplen, startpath-1)
      else
        urladdr = url:sub(skiplen)
      end

      -- if no port given, default it to :80
      if not urladdr:match(':%d+$') then
        urladdr = urladdr .. ':80'
      end
      
      if validate_address(urladdr) then
        return method, url
      else
        msg = 'Invalid IP:Port address provided'
      end

    else
      msg = "URL does not start with 'http://' or 'https://'"
    end
  else
    msg = "Request string does not start with valid method ('GET:' or 'POST:' or 'PUT:')"
  end
  
  if not silent then; log.warn (msg); end
  return nil
  
end

local function normalize(parm)

  if parm == 'null' or parm == '--' or parm == '' then
    return nil
  else
    return parm
  end

end

local function addheaders(headerlist)

  local found_accept = false
  local headers = {}

  if headerlist then
    
    local items = {}
    
    for element in string.gmatch(headerlist, '([^,]+)') do
      table.insert(items, element);
    end
    
    local i = 0
    for _, header in ipairs(items) do
      key, value = header:match('([^=]+)=([^=]+)$')
      key = key:gsub("%s+", "")
      value = value:match'^%s*(.*)'
      if key and value then
        headers[key] = value
        if string.lower(key) == 'accept' then; found_accept = true; end
      end
    end
  end
  
  if not found_accept then
    headers["Accept"] = '*/*'
  end
  
  return headers
end


local function encode_spaces(url)

  local space_idx = 0
  local newurl = url
  
  while space_idx ~= nil do
    space_idx = newurl:find(' ', 1)
    if space_idx then
      local p1 = string.sub(newurl, 1, space_idx-1)
      local p2 = string.sub(newurl, space_idx+1)
      newurl = p1 .. '%20' .. p2
    end
    
  end

  return newurl

end


-- Send http or https request and emit response, or handle errors
local function issue_request(device, req_method, req_url, sendbody, optheaders)

  local responsechunks = {}
  local body, code, headers, status
  
  local protocol = req_url:match('^(%a+):')
  
  local sendheaders = addheaders(optheaders)
  
  if sendbody then
    sendheaders["Content-Length"] = string.len(sendbody)
  end
  
  req_url = encode_spaces(req_url)
  
  if protocol == 'https' and sendbody then
  
    body, code, headers, status = https.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      protocol = "any",
      options =  {"all"},
      verify = "none",
      source = ltn12.source.string(sendbody),
      sink = ltn12.sink.table(responsechunks)
     }

  elseif protocol == 'https' then
  
    body, code, headers, status = https.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      protocol = "any",
      options =  {"all"},
      verify = "none",
      sink = ltn12.sink.table(responsechunks)
     }

  elseif protocol == 'http' and sendbody then
    body, code, headers, status = http.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      source = ltn12.source.string(sendbody),
      sink = ltn12.sink.table(responsechunks)
     }
     
  else
    body, code, headers, status = http.request{
      method = req_method,
      url = req_url,
      headers = sendheaders,
      sink = ltn12.sink.table(responsechunks)
     }
  end

  local response = table.concat(responsechunks)
  
  log.info(string.format("response code=<%s>, status=<%s>", code, status))
  
  local returnstatus = 'unknown'
  local old_driver = device.device_network_id:find('webrequest', 1, 'plaintext')
  local httpcode_str
  local httpcode_num
  protocol = string.upper(protocol)
  
  if type(code) == 'number' then
    httpcode_num = code
  else
    httpcode_str = code
  end
  
  if httpcode_num then
    if old_driver and ((httpcode_num < 200) or (httpcode_num >= 300)) then
      device:emit_event(cap_response.response(string.format('**%s error %s', protocol, tostring(httpcode_num))))
    else
      device:emit_event(cap_httpcode.httpcode(tostring(httpcode_num)))
    end
  end

  if httpcode_num then
    if (httpcode_num >= 200) and (httpcode_num < 300) then
      returnstatus = 'OK'
      log.debug (string.format('Response:\n>>>%s<<<', response))
      
      if response ~= '' then
        device:emit_event(cap_response.response(response:sub(1,1024)))
        
        if device.preferences.valuekey then
          if device.preferences.valuekey ~= 'x1x' then
            local kvalue = parser.findkeyvalue(response, device.preferences.valuekey)
            
            if kvalue ~= nil then
              if device.preferences.dashboard == 'extractnum' then
                device:emit_event(cap_keynumvalue.keynumvalue(tonumber(kvalue)))
              elseif device.preferences.dashboard == 'extracttemp' then
                device:emit_event(cap_keynumvalue.keynumvalue(tonumber(kvalue)))
                device:emit_component_event(device.profile.components.main, capabilities.temperatureMeasurement.temperature({value=tonumber(kvalue), unit='C'}))
              elseif device.preferences.dashboard == 'extractdkh' then
                local num = tonumber(kvalue)
                if num then
                  device:emit_event(cap_dkhvalue.dkh(num))
                  device:emit_event(cap_dkhvalue.dkhtext(string.format('%.3f dKH', num)))
                  -- 앱 기록 그래프용: 커스텀 capability 는 그래프가 없고, 온도는 플랫폼이 1자리로 반올림,
                  -- CO2 는 앱이 정수만 표시하므로 1000배로 발행 (7.29 dKH → 7290 ppm)
                  device:emit_component_event(device.profile.components.main, capabilities.carbonDioxideMeasurement.carbonDioxide({value=math.floor(num*1000+0.5), unit='ppm'}))
                else
                  device:emit_event(cap_dkhvalue.dkhtext(tostring(kvalue)))
                end
              else
                device:emit_event(cap_keyvalue.keyvalue(tostring(kvalue)))
              end
            else
              device:emit_event(cap_keyvalue.keyvalue('--', { visibility = { displayed = false } }))
              device:emit_event(cap_keynumvalue.keynumvalue(26, { visibility = { displayed = false } }))
            end
          end
        else
          device:emit_event(cap_keyvalue.keyvalue('--', { visibility = { displayed = false } }))
          device:emit_event(cap_keynumvalue.keynumvalue(26, { visibility = { displayed = false } }))
        end
      else
        if not old_driver then
          device:emit_event(cap_response.response('--', { visibility = { displayed = false } }))
        end
      end
      
    else
      device:emit_event(cap_response.response('--', { visibility = { displayed = false } }))
      log.warn (string.format("HTTP %s request to %s failed with http code %s, status: %s", req_method, req_url, tostring(httpcode_num), status))
      returnstatus = 'Failed'
    end
  
  else
    
    if httpcode_str then
      if string.find(httpcode_str, "closed") then
        log.warn ("Socket closed unexpectedly")
        returnstatus = "No response"
      elseif string.find(httpcode_str, "refused") then
        log.warn("Connection refused: ", req_url)
        returnstatus = "Refused"
      elseif string.find(httpcode_str, "timeout") then
        log.warn("HTTP request timed out: ", req_url)
        returnstatus = "Timeout"
      else
        log.error (string.format("HTTP %s request to %s failed with code: %s, status: %s", req_method, req_url, httpcode_str, status))
        returnstatus = 'Failed'
      end
    else
      log.warn ("No response code returned")
      returnstatus = "No response code"
    end

    if old_driver then
      device:emit_event(cap_response.response('**'..returnstatus))
    else
      device:emit_event(cap_httpcode.httpcode('**'..returnstatus))
      device:emit_event(cap_response.response('--', { visibility = { displayed = false } }))
    end
    
  end

  return returnstatus
  
end


local function create_another_device(driver, counter)

  log.info("Creating additioal Web Request device")
  
  local MFG_NAME = 'SmartThings Community'
  local VEND_LABEL = string.format('Web Req Multi #%d', counter)
  local MODEL = 'webrequestormv1'
  local ID = 'webreqm' .. '_' .. socket.gettime()
  local PROFILE = NUMBER_DEVICEADDLPROFILE

  log.debug (string.format('Creating additional device: label=<%s>, id=<%s>', VEND_LABEL, ID))

  -- Create master device

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL,
                            }
                      
  assert (driver:try_create_device(create_device_msg), "failed to create additional webreq device")

end


-- Selection made in timer, refresh device
local function refresh_device(device)

  log.debug("Web request selection = " .. 'GET', tostring(device.preferences.refreshurl))

	local reqnumber = device.preferences.refreshurl
  
  if type(reqnumber) == 'number' then

    if type(webreq_commands[device.id][reqnumber]) == 'table' then
      
      local body = webreq_commands[device.id][reqnumber].body
      
      local headers = webreq_commands[device.id][reqnumber].headers
      
      log.info (string.format('SEND %s COMMAND: %s', webreq_commands[device.id][reqnumber].method, webreq_commands[device.id][reqnumber].url))
      log.info (string.format('\twith body: %s', body))
      log.info (string.format('\twith headers: %s', headers))
      device.thread:queue_event(issue_request, device, webreq_commands[device.id][reqnumber].method, webreq_commands[device.id][reqnumber].url, body, headers)
      
    else
      log.debug (string.format('Web request #%d not configured', reqnumber))
    end    
  end
end


-- Start automatic periodic refresh timer
local function restart_timer(driver, device)

  if device:get_field('periodictimer') then                                          -- just in case
    driver:cancel_timer(device:get_field('periodictimer'))
  end
  local periodic_timer = driver:call_on_schedule(device.preferences.refreshrate * 60,
    function()
      refresh_device(device)
    end, 'Refresh timer')
  device:set_field('periodictimer', periodic_timer)

end


-----------------------------------------------------------------------
--										COMMAND HANDLERS
-----------------------------------------------------------------------

-- Selection made in mobile app
local function handle_selection(driver, device, command)

  log.debug("Web request selection = " .. command.command, command.args.value)
  
	local reqnumber = tonumber(command.args.value)
  
  if type(reqnumber) == 'number' then

    if type(webreq_commands[device.id][reqnumber]) == 'table' then
      device:emit_event(cap_select.selection(command.args.value))
      
      local body = webreq_commands[device.id][reqnumber].body
      
      local headers = webreq_commands[device.id][reqnumber].headers
      
      log.info (string.format('SEND %s COMMAND: %s', webreq_commands[device.id][reqnumber].method, webreq_commands[device.id][reqnumber].url))
      log.info (string.format('\twith body: %s', body))
      log.info (string.format('\twith headers: %s', headers))
      device.thread:queue_event(issue_request, device, webreq_commands[device.id][reqnumber].method, webreq_commands[device.id][reqnumber].url, body, headers)
      
    else
      log.debug (string.format('Web request #%d not configured', reqnumber))
      device:emit_event(cap_select.selection('Not configured'))
    end
    
    driver:call_with_delay(5, function() 
                                device:emit_event(cap_select.selection(' ', { visibility = { displayed = false }, state_change = true }))
                              end, 'clear msg')
  end
end

-- Request coming from automation routine/rule or RESTful API
local function handle_requestcmd(_, device, command)

  log.debug (string.format('%s command Received; url = %s; body = %s; headers = %s', command.command, command.args.url, command.args.body, command.args.headers))
  
  if (command.command == 'GET') or (command.command == 'POST') then
  
    if command.args.url ~= nil then
    
      local url = command.args.url
      local body = command.args.body
      
      if body == nil then
        -- See if there is an appended body in the URL string
        local delim_idx = command.args.url:find(BODYDELIM)
        if delim_idx then
          body = string.sub(command.args.url, delim_idx + BODYDELIM:len())
          url = string.sub(command.args.url, 1, delim_idx-1)
        end
      end
        
      local headers = command.args.headers
      
      if headers == nil then
        local optheaders = device.preferences.autoheaders
        if optheaders ~= nil and optheaders ~= 'null' and optheaders ~= '--' and optheaders ~= '' then
          headers = optheaders
        end
      end
      
      device.thread:queue_event(issue_request, device, command.command, url, body, headers)
    else
      log.error ('\tURL command argument missing')
    end
  else
    log.error ('\tUnrecognized command (method)')
  end

end


local function handle_createdev(driver, device, command)

  log.debug ('Createdev handler- command received:', command.command)
  
  devcounter = devcounter + 1
  
  create_another_device(driver, devcounter)

end

------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  
  local profile = profile_for(device)
  log.debug (string.format('Device <%s> is master? %s; profile %s', device.label, tostring(is_master(device)), profile))
  device:try_update_metadata({profile = profile})

  webreq_commands[device.id] = {}

  for key, value in pairs(device.preferences) do
    
    local pnum = tonumber(key:match('request(%d+)'))
    if pnum then
      local method, url = validate(value, true)
            
      if url ~= nil then
        log.debug (string.format('Web request string #%d initialized', pnum))
        webreq_commands[device.id][pnum] = {}
        webreq_commands[device.id][pnum].method = method
        webreq_commands[device.id][pnum].url = url
        
        if pnum <= 5 then
          local body = normalize(device.preferences['body'..tostring(pnum)])
          if body then
            local body_part2 = normalize(device.preferences['bodyb'..tostring(pnum)])
            if body_part2 then
              body = body .. body_part2
            end
          end
          log.debug (string.format('Stashing body: %s', body))
          webreq_commands[device.id][pnum].body = body
          
          webreq_commands[device.id][pnum].headers = normalize(device.preferences['headers'..tostring(pnum)])
          
        end
      end
    end
    ------------------------------------------------------------

    if device.preferences.autorefresh == 'enabled' then
      restart_timer(driver, device)
    else
      log.warn('Configuration required')
    end
  end

  initialized = true
  device:emit_event(cap_select.selection(' ', { visibility = { displayed = false } }))
  device:online()
  
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

	device:emit_event(cap_httpcode.httpcode(' '))
	device:emit_event(cap_response.response(' '))
	device:emit_event(cap_keyvalue.keyvalue(' '))
  device:emit_event(cap_keynumvalue.keynumvalue(26))
  if device:supports_capability_by_id('temperatureMeasurement') then
    device:emit_component_event(device.profile.components.main, capabilities.temperatureMeasurement.temperature({value=26, unit='C'}))
  end
  if device:supports_capability_by_id('cleverflower44023.dkhvalue') then
    device:emit_event(cap_dkhvalue.dkh(0))
    device:emit_event(cap_dkhvalue.dkhtext('--'))
  end
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  -- Nothing to do here!

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)
  
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")

  local periodic_timer = device:get_field('periodictimer')
  if periodic_timer then
    driver:cancel_timer(periodic_timer)
  end
  
  local device_list = driver:get_devices()
  
  if #device_list == 0 then
    initialized = false
  end
  
end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  -- Did preferences change?
  if args.old_st_store.preferences then
  
    if args.old_st_store.preferences.valuekey ~= device.preferences.valuekey then
      log.info (string.format('Value key changed to %s', device.preferences.valuekey))
      
    elseif args.old_st_store.preferences.timeout ~= device.preferences.timeout then
      log.info (string.format('Timeout changed to %s', device.preferences.timeout))
      http.TIMEOUT = device.preferences.timeout
      https.TIMEOUT = device.preferences.timeout
    end

    -- Examine each request# to see if it changed 

    local restarttimer = false
    
    for key, value in pairs(device.preferences) do
    
      local pnum = tonumber(key:match('request(%d+)'))
      
      if pnum then 
      
        if args.old_st_store.preferences[key] ~= device.preferences[key] then
        
          log.info (string.format('Request #%d string changed to: %s', pnum, value))
          
          -- parse & validate the string
          local method, url = validate(value, false)
          
          if url ~= nil then
            log.info (string.format('\tRequest string #%d is valid', pnum))
            if webreq_commands[device.id][pnum] == nil then
              webreq_commands[device.id][pnum] = {}
            end
            webreq_commands[device.id][pnum].method = method
            webreq_commands[device.id][pnum].url = url
          else
            log.warn (string.format('\tInvalid Request string #%d -- ignored', pnum))
            webreq_commands[device.id][pnum] = nil
          end
        end
      end
    end

    -- Store optional bodies for request #1-5
    for idx = 1, 5 do
      if args.old_st_store.preferences['body'..idx] ~= device.preferences['body'..tostring(idx)] or
         args.old_st_store.preferences['bodyb'..idx] ~= device.preferences['bodyb'..tostring(idx)] then
        if webreq_commands[device.id][idx] then
          local body = device.preferences['body'..tostring(idx)]
          log.debug (string.format('\tbody: %s, length= %s', body, body:len()))
          body = normalize(body)
          if body then
            local body_part2 = normalize(device.preferences['bodyb'..tostring(idx)])
            if body_part2 then
              body = body .. body_part2
            end
          end
          log.debug (string.format('Stashing body: %s', body))
          webreq_commands[device.id][idx].body = body
        end
      end
      
      if args.old_st_store.preferences['headers'..idx] ~= device.preferences['headers'..tostring(idx)] then
        if webreq_commands[device.id][idx] then
          local headers = device.preferences['headers'..tostring(idx)]
          log.debug (string.format('headers: %s, length= %s', headers, headers:len()))
          headers = normalize(headers)
          log.debug (string.format('Stashing headers: %s', headers))
          webreq_commands[device.id][idx].headers = headers
        end
      end
    end
    
    -- Restart timer when changed the values of autorefresh, periodictimer
    if args.old_st_store.preferences.autorefresh ~= device.preferences.autorefresh then
      if device.preferences.autorefresh == 'disabled' and device:get_field('periodictimer') then
        driver:cancel_timer(device:get_field('periodictimer'))
        device:set_field('periodictimer', nil)
      elseif device.preferences.autorefresh == 'enabled' then
        restarttimer = true
      end
    
    elseif args.old_st_store.preferences.refreshrate ~= device.preferences.refreshrate then
      if device.preferences.autorefresh == 'enabled' then
        restarttimer = true
      end

    elseif args.old_st_store.preferences.dashboard ~= device.preferences.dashboard then
      log.info ('Dashboard preference changed to: ', device.preferences.dashboard)

      device:try_update_metadata({profile = profile_for(device)})
    end
    
    if restarttimer then; restart_timer(driver, device); end

  else
    log.warn ('Old preferences missing')
  end  
     
end


-- Create Primary Creator Device
local function discovery_handler(driver, _, should_continue)
  
  if not initialized then
  
    log.info("Creating Web Request-Auto device")
    
    local MFG_NAME = 'SmartThings Community'
    local VEND_LABEL = 'Web Req Multi-Auto Master'
    local MODEL = 'webrequestormautov1'
    local ID = 'webreqmauto' .. '_' .. socket.gettime()
    local PROFILE = NUMBER_DEVICEPROFILE

    -- Create master device
	
		local create_device_msg = {
																type = "LAN",
																device_network_id = ID,
																label = VEND_LABEL,
																profile = PROFILE,
																manufacturer = MFG_NAME,
																model = MODEL,
																vendor_provided_label = VEND_LABEL,
															}
												
		assert (driver:try_create_device(create_device_msg), "failed to create web request device")
    
    log.debug("Exiting device creation")
    
  else
    log.info ('Web request device already created')
  end
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
webreqDriver = Driver("webreqDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  
  capability_handlers = {
  
    [cap_select.ID] = {
      [cap_select.commands.setSelection.NAME] = handle_selection,
    },
    [cap_requestcmd.ID] = {
      [cap_requestcmd.commands.POST.NAME] = handle_requestcmd,
      [cap_requestcmd.commands.GET.NAME] = handle_requestcmd,
    },
    [cap_apireqcmd.ID] = {
      [cap_apireqcmd.commands.GET.NAME] = handle_requestcmd,
      [cap_apireqcmd.commands.POST.NAME] = handle_requestcmd,
    },
    [cap_createdev.ID] = {
      [cap_createdev.commands.push.NAME] = handle_createdev,
    },
  }
})

log.info ('Web Requestor Multi-Auto Driver v1.5 Started')

webreqDriver:run()
