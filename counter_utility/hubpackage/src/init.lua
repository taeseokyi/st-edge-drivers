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

  Edge utility device driver - track switch on duration and increment/decrement counter


  Modified by Taeseok Yi, 2026 (version 0.8):
  - profile names changed to edgeutil.v1c / edgeutil_count.v1c
  - device:online() in device_init/device_added so health recovers after hub reconnect
  - contact sensor behavior 'disable' no longer aborts the switch handler
  - 'increment' preference: count step for add/subtract and switch-linked counting
  - 'resetnum' (reset counter to a given number) command handled
  - auto-refresh timer is aligned to the duration base time, so values stay on
    frequency boundaries (5, 10, 15 ...) across resets and driver restarts
  - preference changes (frequency / scale / switchoff / behavior / dashboard) each take
    effect immediately
  - defensive fallbacks for missing or invalid preferences; globals removed
  - devices migrated from another driver are moved onto this driver's profile once at init

  Version 0.9 (2026-11-02):
  - dashboard text capability (cleverflower44023.dashtext) shows the count with a unit ("회")
  - 'both' dashboard option: duration and count on one tile (profile edgeutil_both.v1d),
    duration shown with a short unit (분/시간/...) to keep the tile narrow
  - profile names bumped to v1d; profile sync re-runs whenever the wanted profile name changes
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local socket = require "cosock.socket"          -- just for time
local log = require "log"


-- Module variables
local thisDriver                                -- assigned at the bottom (Driver(...))
local initialized = false

local DURATION_PROFILE = 'edgeutil.v1d'
local COUNT_PROFILE = 'edgeutil_count.v1d'
local BOTH_PROFILE = 'edgeutil_both.v1d'

local COUNT_UNIT = '회'                         -- unit shown after the count on the dashboard

-- short duration unit for the combined ('both') dashboard text; the full scale name
-- ('minutes') made the tile too long next to the count
local SHORT_UNIT = {
  seconds = '초',
  minutes = '분',
  hours   = '시간',
  days    = '일',
  weeks   = '주',
}

local DEFAULT_SCALE = 'hours'                   -- matches the profile default
local DEFAULT_FREQUENCY = 1800                  -- seconds, matches the profile default
local MIN_FREQUENCY = 10

local SCALE_DIVISOR = {
  seconds = 1,
  minutes = 60,
  hours   = 3600,
  days    = 86400,
  weeks   = 604800,
}

-- contact sensor value per switch state, keyed by the 'behavior' preference.
-- 'disable' (or anything unknown) has no entry: the contact sensor is left alone.
local CONTACT_MAP = {
  on_open   = { on = 'open',   off = 'closed' },
  on_closed = { on = 'closed', off = 'open'   },
}

-- Custom Capabilities

local cap_duration = capabilities["partyvoice23922.duration2"]
local cap_count    = capabilities["partyvoice23922.count"]
local cap_add      = capabilities["partyvoice23922.add2"]
local cap_subtract = capabilities["partyvoice23922.subtract2"]
local cap_reset    = capabilities["partyvoice23922.resetalt"]
local cap_resetnum = capabilities["partyvoice23922.resetnum"]
local cap_create   = capabilities["partyvoice23922.createanother"]
local cap_dashtext = capabilities["cleverflower44023.dashtext"]


-----------------------------------------------------------------------
--                        PREFERENCE ACCESSORS
-----------------------------------------------------------------------

local function get_scale(device)

  local scale = device.preferences.scale
  if SCALE_DIVISOR[scale] == nil then
    log.warn(string.format('Invalid scale preference <%s>; using %s', tostring(scale), DEFAULT_SCALE))
    scale = DEFAULT_SCALE
  end
  return scale

end

local function get_frequency(device)

  local frequency = tonumber(device.preferences.frequency)
  if frequency == nil then
    log.warn(string.format('Missing frequency preference; using %d', DEFAULT_FREQUENCY))
    frequency = DEFAULT_FREQUENCY
  elseif frequency < MIN_FREQUENCY then
    frequency = MIN_FREQUENCY
  end
  return math.floor(frequency)

end

local function get_count_step(device)

  local step = tonumber(device.preferences.increment)
  if step == nil or step < 1 then
    step = 1
  end
  return math.floor(step)

end

local function desired_profile(device)

  local mode = device.preferences.dashboard
  if mode == 'count' then
    return COUNT_PROFILE
  elseif mode == 'both' then
    return BOTH_PROFILE
  end
  return DURATION_PROFILE

end

-- Move the device onto this driver's own profile (once per profile name). Devices that
-- came over from another driver keep that driver's profile and presentation until the
-- driver asks for a change; the dashboard preference decides which of our profiles
-- applies. The synced name is remembered so a new profile version is picked up at init.
local function sync_profile(device)

  local profile = desired_profile(device)
  if device:get_field('profileSynced') == profile then
    return
  end
  log.info (string.format('Syncing device profile to %s', profile))
  device:try_update_metadata({profile = profile})
  device:set_field('profileSynced', profile, {persist = true})

end

local function is_switch_on(device)

  return device:get_latest_state('main', capabilities.switch.ID, capabilities.switch.switch.NAME) == 'on'

end


-----------------------------------------------------------------------
--                        DEVICE CREATION
-----------------------------------------------------------------------

local function create_device(driver)

  local MFG_NAME = 'SmartThings Community'
  local MODEL = 'edgeUtil'
  local VEND_LABEL = 'Counter Utility'
  local ID = 'edgeUtility_' .. socket.gettime()
  local PROFILE = DURATION_PROFILE

  log.info (string.format('Creating new device: label=<%s>, id=<%s>', VEND_LABEL, ID))

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL,
                            }

  assert (driver:try_create_device(create_device_msg), "failed to create device")

end


-----------------------------------------------------------------------
--                        DURATION / COUNT STATE
-----------------------------------------------------------------------

local function get_count(device)

  return device:get_latest_state('counter', cap_count.ID, cap_count.count.NAME) or 0

end

local function get_duration(device)

  return device:get_latest_state('main', cap_duration.ID, cap_duration.duration.NAME) or 0

end

-- Dashboard text for the 'count' and 'both' dashboard modes. The count is shown with
-- COUNT_UNIT; 'both' prefixes the duration with a short unit. Skipped silently when the
-- current profile has no dashtext capability (duration mode, or profile not yet switched).
local function update_dashtext(device, duration, count)

  if not device:supports_capability_by_id(cap_dashtext.ID, 'main') then
    return
  end

  local mode = device.preferences.dashboard
  if mode ~= 'count' and mode ~= 'both' then
    return
  end

  local text = string.format('%d %s', count or get_count(device), COUNT_UNIT)
  if mode == 'both' then
    text = string.format('%d %s / %s', duration or get_duration(device), SHORT_UNIT[get_scale(device)], text)
  end

  device:emit_component_event(device.profile.components.main, cap_dashtext.text(text))

end

local function _update_duration(device, duration)

  device:emit_component_event(device.profile.components.main,
                              cap_duration.duration({value = duration, unit = get_scale(device)}))
  update_dashtext(device, duration, nil)

end

local function _update_count(device, count)

  device:emit_component_event(device.profile.components.counter, cap_count.count(count))
  update_dashtext(device, nil, count)

end


local function calc_duration(device)

  local basetime = device:get_field('baseTime')
  if not basetime then
    return 0
  end

  local rawduration = os.time() - basetime
  if rawduration < 0 then          -- clock went backwards
    rawduration = 0
  end

  return math.floor(rawduration / SCALE_DIVISOR[get_scale(device)])

end


local function refresh_duration(device)

  _update_duration(device, calc_duration(device))

end


-----------------------------------------------------------------------
--                        AUTO REFRESH TIMER
-----------------------------------------------------------------------

local function stop_auto_refresh(device)

  local refreshtimer = device:get_field('refreshtimer')
  if refreshtimer then
    thisDriver:cancel_timer(refreshtimer)
    device:set_field('refreshtimer', nil)
  end

end


-- Periodic duration refresh. The first tick is placed on the next multiple of
-- 'frequency' seconds after baseTime, so that reported values land on 5, 10, 15 ...
-- regardless of when the timer itself was (re)started (reset, driver restart).
local function start_auto_refresh(device)

  stop_auto_refresh(device)

  local frequency = get_frequency(device)

  local function start_periodic()
    local timer = device.thread:call_on_schedule(frequency,
                                                 function() refresh_duration(device) end,
                                                 'duration refresh')
    device:set_field('refreshtimer', timer)
  end

  local basetime = device:get_field('baseTime')
  local delay = frequency
  if basetime then
    local elapsed = os.time() - basetime
    if elapsed > 0 then
      delay = frequency - (elapsed % frequency)
    end
  end

  if delay >= frequency then
    start_periodic()
  else
    log.debug (string.format('Aligning refresh timer: first tick in %d s, then every %d s', delay, frequency))
    local timer = device.thread:call_with_delay(delay,
                                                function()
                                                  refresh_duration(device)
                                                  start_periodic()
                                                end,
                                                'duration refresh align')
    device:set_field('refreshtimer', timer)
  end

end


-----------------------------------------------------------------------
--                        COUNTER
-----------------------------------------------------------------------

local function increment_count(device)

  _update_count(device, get_count(device) + get_count_step(device))

end

local function decrement_count(device)

  local current_count = get_count(device)
  if current_count > 0 then
    _update_count(device, math.max(current_count - get_count_step(device), 0))
  end

end


-----------------------------------------------------------------------
--                        COMMAND HANDLERS
-----------------------------------------------------------------------

local function handle_switch(driver, device, command)

  local newstate = command.command
  log.info ('Switch turned >> ' .. newstate .. ' <<')

  device:emit_event(capabilities.switch.switch(newstate))

  -- Mirror the switch onto the hidden contact sensor if the preference asks for it
  local contactset = CONTACT_MAP[device.preferences.behavior]
  if contactset then
    device:emit_event(capabilities.contactSensor.contact(contactset[newstate]))
  end

  -- Don't do anything else if a duplicate
  if device:get_field('lastcmd') == newstate then
    return
  end

  -- Manage duration tracking

  local duration
  local basetime = device:get_field('baseTime')
  local pausetime = device:get_field('pauseTime')
  log.debug (string.format('SW basetime=%s pausetime=%s', tostring(basetime), tostring(pausetime)))

  if newstate == 'on' then

    if basetime == nil or not pausetime or pausetime == 0 then
      -- fresh start (no base time, or base time without a matching pause)
      device:set_field('baseTime', os.time(), {persist = true})
      duration = 0
    else
      -- resume: shift the base time forward by the length of the pause
      local newbase = basetime + (os.time() - pausetime)
      device:set_field('baseTime', newbase, {persist = true})
      log.debug ('\tSW new basetime=', newbase)
      duration = calc_duration(device)
    end
    device:set_field('pauseTime', 0, {persist = true})

    if device.preferences.countlink == 'counton' or device.preferences.countlink == 'countany' then
      increment_count(device)
    end

    start_auto_refresh(device)

  else      -- switch == OFF

    stop_auto_refresh(device)

    if device.preferences.switchoff == 'pause' and basetime then
      device:set_field('pauseTime', os.time(), {persist = true})
      duration = calc_duration(device)
    else
      device:set_field('pauseTime', 0, {persist = true})
      device:set_field('baseTime', nil, {persist = true})
      duration = 0
    end

    if device.preferences.countlink == 'countoff' or device.preferences.countlink == 'countany' then
      increment_count(device)
    end

  end

  _update_duration(device, duration)
  device:set_field('lastcmd', newstate)

end


local function handle_addbutton(driver, device, command)

  log.info ('Add Button pressed')

  increment_count(device)

end

local function handle_subtractbutton(driver, device, command)

  log.info ('Subtract Button pressed')

  decrement_count(device)

end


local function handle_reset(driver, device, command)

  log.info ('Reset button pressed; component:', command.component)

  if command.component == 'main' then

    _update_duration(device, 0)
    device:set_field('pauseTime', 0, {persist = true})

    if is_switch_on(device) then
      device:set_field('baseTime', os.time(), {persist = true})
      -- re-align the refresh timer with the new base time
      start_auto_refresh(device)
    else
      device:set_field('baseTime', nil, {persist = true})
      stop_auto_refresh(device)
    end

  elseif command.component == 'counter' then

    _update_count(device, 0)

  end

end


-- Reset the counter to a user-supplied number (partyvoice23922.resetnum / resetValue)
local function handle_resetnum(driver, device, command)

  local value = tonumber(command.args and command.args.resetvalue)
  log.info ('Reset counter to number requested; value:', tostring(value))

  if value == nil or value < 0 then
    log.warn ('Ignoring invalid reset value')
    return
  end
  value = math.floor(value)

  device:emit_component_event(device.profile.components.counter, cap_resetnum.numberval(value))
  _update_count(device, value)

end


local function handle_create(driver, device, command)

  log.info ('Create device requested')

  create_device(driver)

end


local function handle_stockrefresh(driver, device, command)

  log.info ('Stock refresh requested; component:', command.component)

  if is_switch_on(device) then
    refresh_duration(device)
  end

end


------------------------------------------------------------------------
--             REQUIRED EDGE DRIVER LIFECYCLE HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)

  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")

  refresh_duration(device)

  local currswitchstate = device:get_latest_state('main', capabilities.switch.ID, capabilities.switch.switch.NAME)
  device:set_field('lastcmd', currswitchstate)

  if currswitchstate == 'on' then
    start_auto_refresh(device)
  end

  sync_profile(device)

  initialized = true
  device:online()

end


-- Called when device is first created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

  stop_auto_refresh(device)

  device:emit_event(capabilities.switch.switch('off'))
  device:emit_event(capabilities.contactSensor.contact('closed'))

  _update_duration(device, 0)
  _update_count(device, 0)
  device:set_field('pauseTime', 0, {persist = true})
  device:set_field('baseTime', nil, {persist = true})
  device:set_field('lastcmd', 'off')
  device:online()

end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  log.info ('Device doConfigure lifecycle invoked')

end


-- Called when device was deleted
local function device_removed(driver, device)

  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")

  stop_auto_refresh(device)

  local device_list = driver:get_devices()

  if #device_list == 0 then
    log.warn('No more devices; driver not active')
    initialized = false
  end

end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end


local function handle_pref_changes(device, oldprefs, prefs)

  -- Each preference is checked on its own; several may change at once.

  if oldprefs.frequency ~= prefs.frequency then
    log.info ('Refresh frequency changed to: ', prefs.frequency)
    if is_switch_on(device) then
      start_auto_refresh(device)
    end
  end

  if oldprefs.scale ~= prefs.scale then
    log.info ('Duration scale changed to: ', prefs.scale)
    refresh_duration(device)
  end

  if oldprefs.switchoff ~= prefs.switchoff then
    log.info ('Switch off action changed to: ', prefs.switchoff)
    -- Switching from 'pause' to 'reset' while paused: drop the paused duration now
    if prefs.switchoff == 'reset' and not is_switch_on(device) then
      device:set_field('pauseTime', 0, {persist = true})
      device:set_field('baseTime', nil, {persist = true})
      _update_duration(device, 0)
    end
  end

  if oldprefs.behavior ~= prefs.behavior then
    log.info ('Contact sensor behavior changed to: ', prefs.behavior)
    -- Bring the hidden contact sensor in line with the current switch state right away
    local contactset = CONTACT_MAP[prefs.behavior]
    if contactset then
      device:emit_event(capabilities.contactSensor.contact(contactset[is_switch_on(device) and 'on' or 'off']))
    end
  end

  if oldprefs.dashboard ~= prefs.dashboard then
    log.info ('Dashboard preference changed to: ', prefs.dashboard)
    sync_profile(device)
  end

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  local oldprefs = args.old_st_store and args.old_st_store.preferences
  local prefs = device.preferences

  if oldprefs then
    handle_pref_changes(device, oldprefs, prefs)
  end

  -- Also fires once a profile switch has landed; the dashboard text can only be
  -- emitted when a profile with the dashtext capability is active.
  update_dashtext(device, nil, nil)

end


local function shutdown_handler(driver, event)

  if event == 'shutdown' then
    log.warn('*** Driver shutdown ***')
  end

end


-- Discovery (when 'Scan for nearby devices' invoked from mobile app)
local function discovery_handler(driver, _, should_continue)

  if not initialized then

    log.info("Creating counter device")

    create_device(driver)

    log.debug("Exiting device creation")

  else
    log.info ('At least one counter device already exists')
  end
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("thisDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {

    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
    },
    [cap_add.ID] = {
      [cap_add.commands.push.NAME] = handle_addbutton,
    },
    [cap_subtract.ID] = {
      [cap_subtract.commands.push.NAME] = handle_subtractbutton,
    },
    [cap_reset.ID] = {
      [cap_reset.commands.push.NAME] = handle_reset,
    },
    [cap_resetnum.ID] = {
      [cap_resetnum.commands.resetValue.NAME] = handle_resetnum,
    },
    [cap_create.ID] = {
      [cap_create.commands.push.NAME] = handle_create,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_stockrefresh,
    },
  }
})

log.info ('Edge Counter-utility Device Version 0.9')


thisDriver:run()
