--[[============================================================================
export.lua
============================================================================]]--

--[[

ProcessSlicer() related...

I tried to make an OO class, but yield would throw:
$ Error: attempt to yield across metamethod/C-call boundary

I also tried to make a Lua module, but I got:
$ Error: attempt to get length of upvalue [...]

Dinked around for hours, gave up.
Thusly, this file is procedural. Each function is to be prepended with `export_`
Good times.

]]-- 

--------------------------------------------------------------------------------
-- Variables & Globals, captialized for easier recognition
--------------------------------------------------------------------------------

local MIDI_DIVISION = 96 -- MIDI clicks per quarter note
local MIDI_CHANNEL = 1   -- Initial MIDI channel

local FILEPATH = nil
local RNS = nil
local fancyStatus = nil

local DATA = table.create()
local DATA_BPM = table.create()
local DATA_LPB = table.create()
local DATA_TPL = table.create()
local DATA_TICK_DELAY = table.create()
local DATA_TICK_CUT = table.create()
local DATA_CC = table.create()
local DATA_PB = table.create()
local DATA_CHPR = table.create()
local DATA_META = table.create()

local LPB_LOOKUP_TABLE = table.create()

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------

local getDeviceInTrack = function (thisTrack, targetPath)
    for y = 2, #thisTrack.devices do
        local thisDevice = thisTrack:device(y)
        if (thisDevice.is_active and thisDevice.device_path == targetPath) then
            return thisDevice
        end
    end
    return nil
end

local getAutomationOfDevice = function (thisPatternTrack, thisDevice)
    local result = {}
    local b = 1
    for x = 1, #thisDevice.parameters do
      if (thisDevice.parameters[x].is_automated) then
        local autPointer = thisPatternTrack:find_automation(thisDevice.parameters[x])
        if (autPointer ~= nil) then
          result[b] = autPointer
          b = b + 1
        end
      end
    end
    return result
end

-- Go to next midi channel
function export_ch_rotator()
    MIDI_CHANNEL = MIDI_CHANNEL + 1
    if MIDI_CHANNEL > 16 then MIDI_CHANNEL = 1 end
end

-- MF2T Timestamp
function export_pos_to_time(pos, delay, division, lpb)
    local time = ((pos - 1) + delay / 256) * (division / lpb)
    return math.floor(time + .5) --Round
end


-- Tick to Delay (0.XX)
function export_tick_to_delay(tick, tpl)
    if tick >= tpl then return false end
    local delay = tick * 256 / tpl
    return delay / 256
end


-- Used to sort a table in export_midi()
function export_compare(a, b)
    if (a and a[1] == b[1]) then
        return a[2] < b[2]
    else
        return a[1] < b[1]
    end
end


-- Animate status bar
local status_animation = { "|", "/", "-", "\\" }
local status_animation_pos = 1
function export_status_progress()
    if status_animation_pos >= #status_animation then
        status_animation_pos = 1
    else
        status_animation_pos = status_animation_pos + 1
    end
    return "MIDI Export, Working... " .. status_animation[status_animation_pos]
end


--------------------------------------------------------------------------------
-- Build a data table
--------------------------------------------------------------------------------

local instrumentTrackNames = {}

function export_build_data(plan)

    MIDI_CHANNEL = 1
    DATA:clear(); DATA_BPM:clear(); DATA_LPB:clear(); DATA_TPL:clear()
    DATA_TICK_DELAY:clear(); DATA_TICK_CUT:clear()
    LPB_LOOKUP_TABLE:clear();
    DATA_CC:clear();DATA_PB:clear();DATA_CHPR:clear();DATA_META:clear()

    local instruments = RNS.instruments
    local tracks = RNS.tracks
    local sequencer = RNS.sequencer
    local total_instruments = #instruments
    local total_tracks = #tracks
    local total_sequence = #sequencer.pattern_sequence
    local start = { sequence_index = 1, line_start = 1, line_end = nil }
    local constrain_to_selected = false

    -- Plan
    RNS.transport:stop()
    if plan == 'selection' then
        constrain_to_selected = true
        start.sequence_index = RNS.selected_sequence_index
        start.line_start, start.line_end = selection_line_range()
        total_sequence = start.sequence_index
    else
        RNS.transport.playback_pos = renoise.SongPos(1, 1)
    end

    -- Setup data table
    for i=1,total_instruments do
        DATA[i] = table.create() -- notes
        DATA_CC[i] = table.create() -- midi commands
        DATA_PB[i] = table.create() -- pitchbend commands
        DATA_CHPR[i] = table.create() -- channel pressure commands
        DATA_META[i] = table.create() -- meta data
    end

    local i = 255 -- instrument_value, 255 means empty
    local j = 0 -- e.g. DATA[i][j]
    local trackInstrumentNumbers = {}
    local yc = 1
    local seqNum = 1

    -- # TRACKS
    for track_index=1,total_tracks do

        -- Total must be 1 or more, used to process master and send tracks
        local total_note_columns = 1
        if tracks[track_index].visible_note_columns > 1 then
            total_note_columns = tracks[track_index].visible_note_columns
        end

        -- # NOTE COLUMNS
        for column_index=1,total_note_columns do

            local pattern_current = -1
            local pattern_previous = sequencer.pattern_sequence[1]
            local pattern_length = 0
            local pattern_offset = 0
            if constrain_to_selected then
                pattern_offset = 1 - start.line_start
            end
            local k = 1 -- Pattern counter


            -- # SEQUENCE
            for sequence_index=start.sequence_index,total_sequence do

                local pattern_index = sequencer.pattern_sequence[sequence_index]
                local current_pattern_track = RNS.patterns[pattern_index].tracks[track_index]
                -- # SLOT MUTED
                local seq_muted = RNS.sequencer:track_sequence_slot_is_muted(track_index, sequence_index)

                -- Calculate offset
                if pattern_current ~= sequence_index then
                    pattern_current = sequence_index
                    if k > 1 then
                        pattern_offset = pattern_offset + RNS.patterns[pattern_previous].number_of_lines
                    end
                end

                -- Selection hack
                if constrain_to_selected then
                    pattern_length = start.line_end
                else
                    pattern_length = RNS.patterns[pattern_index].number_of_lines
                end
                
                local pos = pattern_offset

                -- SEQUENCE MARKERS  
                -- TODO: Still wrong position, shifted to left or so,
                -- no idea which DAW supports markers at import at all
                
                if --trackInstrumentNumbers[track_index] ~= nil and
                    i == 1 and pos > 0 and 
                    RNS.sequencer:sequence_section_name(sequence_index) ~= "Untitled Section"
                then
                    DATA_META[i]:insert{
                        pos = pos,
                        msg = "Meta Marker \"" .. RNS.sequencer:sequence_section_name(sequence_index) .. "\"",
                    }
                    --[[
                    DATA_META[i]:insert{
                        pos = pos,
                        msg = "Seqnr " .. seqNum,
                    }
                    seqNum = seqNum + 1
                    DATA_META[1]:insert{
                        pos = pos,
                        msg = "Meta Cue \"" .. RNS.sequencer:sequence_section_name(sequence_index) .. "\"",
                    }
                    if (pos > 0) then
                      DATA_META[1]:insert{
                          pos = pos-1,
                          msg = "Meta TrkEnd",
                      }
                    end
                    DATA_META[1]:insert{
                        pos = pos,
                        msg = "Meta TrkName \"" .. RNS.sequencer:sequence_section_name(sequence_index) .. "\"",
                    }
                    DATA_META[1]:insert{
                        pos = pos,
                        msg = "Meta Lyric \"" .. RNS.sequencer:sequence_section_name(sequence_index) .. "\"",
                    }
                    ]]--
                end
          
                 -- # MIDI CONTROL / AUTOMATION DEVICE
                if trackInstrumentNumbers[track_index] ~= nil and
                    tracks[track_index].type ~= renoise.Track.TRACK_TYPE_GROUP and
                    tracks[track_index].type ~= renoise.Track.TRACK_TYPE_MASTER and
                    tracks[track_index].type ~= renoise.Track.TRACK_TYPE_SEND
                then
                  local deviceTypes = {
                    { path = "Audio/Effects/Native/*Instr. MIDI Control", ccOffset = 20 }, 
                    { path = "Audio/Effects/Native/*Instr. Automation", ccOffset = 102 }
                  }
                  for xd in ipairs(deviceTypes) do
                    local foundDevice = getDeviceInTrack(tracks[track_index], deviceTypes[xd].path)
                    if (foundDevice ~= nil) then
                      local deviceAutomation = getAutomationOfDevice(current_pattern_track, foundDevice)
                      if (deviceAutomation ~= nil) then
                        -- put found automation to midi cc 21-31 and 102-112 (max 10)
                        -- (midi cc 20 is used for pitchbend)
                        local b = 1
                        for x in ipairs(deviceAutomation) do
                          for y = 1, #deviceAutomation[x].points do
                            DATA_CC[i]:insert{
                                cc_pos = pos + deviceAutomation[x].points[y].time,
                                cc_number = string.format("%.2x", deviceTypes[xd].ccOffset + b),
                                cc_value = string.format("%.2x", deviceAutomation[x].points[y].value * 127),
                            }
                          end
                          b = b + 1
                          if (b > 10) then
                            break
                          end
                        end 
                      end             
                    end
                  end
                end
 
                -- Yield every column to avoid timeout nag screens
                -- Makes the script slower 
                 if (yc % 15 == 0) then
                    if COROUTINE_MODE then coroutine.yield() end
                end
                yc = yc + 1
                
                -- # LINES
                for line_index=start.line_start,pattern_length do

                    --------------------------------------------------------------------
                    -- Data chug-a-lug start >>>
                    --------------------------------------------------------------------

                    pos = line_index + pattern_offset

                    -- Look for global changes, don't repeat more than once
                    -- Override pos, from left to right
                    for fx_column_index=1,tracks[track_index].visible_effect_columns do
                        local fx_col = current_pattern_track:line(line_index).effect_columns[fx_column_index]
                        if not constrain_to_selected or
                            constrain_to_selected and fx_col.is_selected then
                            if 'ZT' == fx_col.number_string then
                                -- ZTxx - Set Beats Per Minute (BPM) (20 - FF, 00 = stop song)
                                DATA_BPM[pos] = fx_col.amount_string
                            elseif 'ZL' == fx_col.number_string  then
                                -- ZLxx - Set Lines Per Beat (LPB) (01 - FF, 00 = stop song).
                                DATA_LPB[pos] = fx_col.amount_string
                            elseif 'ZK' == fx_col.number_string  then
                                -- ZKxx - Set Ticks Per Line (TPL) (01 - 10).
                                DATA_TPL[pos] = fx_col.amount_string
                            elseif '0Q' == fx_col.number_string  then
                                -- 0Qxx, Delay all notes by xx ticks.
                                DATA_TICK_DELAY[pos] = fx_col.amount_string
                            end
                        end
                    end

                    if
                        tracks[track_index].type ~= renoise.Track.TRACK_TYPE_GROUP and
                        tracks[track_index].type ~= renoise.Track.TRACK_TYPE_MASTER and
                        tracks[track_index].type ~= renoise.Track.TRACK_TYPE_SEND
                    then

                        -- Sequencer tracks

                        local note_col = current_pattern_track:line(line_index).note_columns[column_index]
                        local fx_col = current_pattern_track:line(line_index).effect_columns[1]

                        -- Look for MIDI commands in the right-most note-column

                        -- Midi control messages (CC)
                        if ('M0' == note_col.panning_string)
                            and (column_index == total_note_columns)
                            and (note_col.instrument_value ~= 255)
                        then
                            DATA_CC[i]:insert{
                                cc_pos = pos,
                                cc_number = fx_col.number_string,
                                cc_value = fx_col.amount_string,
                            }
                        end
                        -- Midi pitchbend messages
                        if ('M1' == note_col.panning_string)
                            and (column_index == total_note_columns)
                            and (note_col.instrument_value ~= 255)
                        then
                            table.insert(DATA_PB[i], {
                                pos = pos,
                                number = fx_col.number_string,
                                value = fx_col.amount_string,
                            })
                        end
                        -- Channel aftertouch messages
                        if ('M3' == note_col.panning_string)
                            and (column_index == total_note_columns)
                            and (note_col.instrument_value ~= 255)
                        then
                            table.insert(DATA_CHPR[i], {
                                pos = pos,
                                value = fx_col.amount_string,
                            })
                        end

                        -- Notes data

                        -- TODO:
                        -- NNA and a more realistic note duration could, in theory,
                        -- be calculated with the length of the sample and the instrument
                        -- ADSR properties.

                        if
                            not constrain_to_selected or
                            constrain_to_selected and note_col.is_selected and not seq_muted
                        then
                            -- Set some defaults
                            local volume = 128
                            local panning = 64
                            local tick_delay = 0 -- Dx - Delay a note by x ticks (0 - F)
                            local tick_cut = nil -- Fx - Cut the note after x ticks (0 - F)
                            -- Volume column
                            if 0 <= note_col.volume_value and note_col.volume_value <= 128 then
                                volume = note_col.volume_value
                            elseif note_col.volume_string:find('Q') == 1 then
                                tick_delay = note_col.volume_string:sub(2)
                            elseif note_col.volume_string:find('C') == 1 then
                                tick_cut = note_col.volume_string:sub(2)
                            end
                            -- Panning col
                            if 0 <= note_col.panning_value and note_col.panning_value <= 128 then
                                panning = note_col.panning_value
                            elseif note_col.panning_string:find('Q') == 1 then
                                tick_delay = note_col.panning_string:sub(2)
                            elseif note_col.panning_string:find('C') == 1 then
                                tick_cut = note_col.panning_string:sub(2)
                            end
                            -- Note OFF
                            if
                                not note_col.is_empty
                                and note_col.note_value < 121
                                and j > 0 and DATA[i][j].pos_end == 0
                                or seq_muted and j > 0 and DATA[i][j].pos_end == 0
                            then
                                dbug("Note-OFF - tick_delay (#"..j..")"
                                    .."\n # instrument_value: "..tostring(note_col.instrument_value)
                                    .."\n # sequence_index: "..tostring(sequence_index)
                                    .."\n # column_index: "..tostring(column_index)
                                    .."\n # line_index: "..tostring(line_index)
                                    .."\n .pos_end: "..tostring(pos)
                                    .."\n .delay_end: "..tostring(note_col.delay_value)
                                    .."\n .tick_delay_end: "..tostring(tick_delay)
                                )
                                DATA[i][j].pos_end = pos
                                DATA[i][j].delay_end = note_col.delay_value
                                DATA[i][j].tick_delay_end = tick_delay
                            elseif
                                tick_cut ~= nil and
                                j > 0 and DATA[i][j].pos_end == 0
                            then
                                dbug("Note-OFF - tick_cut (#"..j..")"
                                    .."\n # instrument_value: "..tostring(note_col.instrument_value)
                                    .."\n # sequence_index: "..tostring(sequence_index)
                                    .."\n # column_index: "..tostring(column_index)
                                    .."\n # line_index: "..tostring(line_index)
                                    .."\n .pos_end: "..tostring(pos)
                                    .."\n .delay_end: "..tostring(note_col.delay_value)
                                    .."\n .tick_delay_end: "..tostring(tick_cut)
                                )
                                DATA[i][j].pos_end = pos
                                DATA[i][j].delay_end = note_col.delay_value
                                DATA[i][j].tick_delay_end = tick_cut
                            end
                            -- Note ON
                            if
                                note_col.instrument_value ~= 255
                                and note_col.note_value < 120
                                and DATA[note_col.instrument_value + 1] ~= nil
                                and not seq_muted
                            then
                                i = note_col.instrument_value + 1 -- Lua vs C++
                                trackInstrumentNumbers[track_index] = i
                                instrumentTrackNames[i] = RNS.tracks[track_index].name
                                
                                -- transpose
                                local transpose = RNS.instruments[i].transpose + RNS.instruments[i].midi_output_properties.transpose + RNS.instruments[i].plugin_properties.transpose
                                local noteValue = note_col.note_value + transpose
                                if (noteValue >= 120) then
                                  noteValue = 119 
                                end
                                if (noteValue < 0) then
                                  noteValue = 0 
                                end
                                
                                DATA[i]:insert{
                                    note = noteValue,
                                    pos_start = pos,
                                    pos_end = 0,
                                    delay_start = note_col.delay_value,
                                    tick_delay_start = tick_delay,
                                    delay_end = 0,
                                    tick_delay_end = 0,
                                    volume = volume,
                                -- panning = panning, -- TODO: Do something with panning var, 
                                -- does Renoise support VSTi pattern command panning at all?
                                -- track = track_index,
                                -- column = column_index,
                                -- sequence_index = sequence_index,
                                }
                                j = table.count(DATA[i])
                                if tick_cut ~= nil then
                                    DATA[i][j].pos_end = pos
                                    DATA[i][j].tick_delay_end = tick_cut
                                end
                                dbug("Note-ON (#"..j..")"
                                    .."\n # instrument_value: "..tostring(note_col.instrument_value)
                                    .."\n # sequence_index: "..tostring(sequence_index)
                                    .."\n # column_index: "..tostring(column_index)
                                    .."\n # line_index: "..tostring(line_index)
                                    .."\n .note: "..tostring(DATA[i][j].note)
                                    .."\n .pos_start: "..tostring(DATA[i][j].pos_start)
                                    .."\n .pos_end: "..tostring(DATA[i][j].pos_end)
                                    .."\n .delay_start: "..tostring(DATA[i][j].delay_start)
                                    .."\n .tick_delay_start: "..tostring(DATA[i][j].tick_delay_start)
                                    .."\n .delay_end: "..tostring(DATA[i][j].delay_end)
                                    .."\n .tick_delay_end: "..tostring(DATA[i][j].tick_delay_end)
                                    .."\n .volume: "..tostring(DATA[i][j].volume)
                                )
                            end
                        end
                        -- Next
                        pattern_previous = sequencer.pattern_sequence[sequence_index]
                    end

                    --------------------------------------------------------------------
                    -- <<< Data chug-a-lug end
                    --------------------------------------------------------------------

                end -- LINES #
                
                -- Increment pattern counter
                k = k + 1

            end -- SEQUENCE #

            -- Insert terminating Note OFF
            if j > 0 and DATA[i][j].pos_end == 0 then
                dbug("Process(build_data()) : Insert terminating Note-OFF")
                DATA[i][j].pos_end = pattern_offset + pattern_length + RNS.transport.lpb
            end

            -- Yield every column to avoid timeout nag screens
            fancyStatus:show_status(export_status_progress())
            --if COROUTINE_MODE then coroutine.yield() end
            dbug(("Process(build_data()) Track: %d; Column: %d")
                :format(track_index, column_index))

        end -- NOTE COLUMNS #

    end -- TRACKS #
end


--------------------------------------------------------------------------------
-- Create and save midi file
--------------------------------------------------------------------------------

-- Note: we often re-use a special `sort_me` table
-- because we need to sort timestamps before they can be added

-- Returns max pos in table
-- (a) is a table where key is pos
function _export_max_pos(a)
    local keys = a:keys()
    local mi = 1
    local m = keys[mi]
    for i, val in ipairs(keys) do
        if val > m then
            mi = i
            m = val
        end
    end
    return m
end


-- Return a float representing, pos, delay, and tick
--
-- * Delay in pan overrides existing delays in volume column.
-- * Delay in effect column overrides delay in volume or pan columns.
-- * Notecolumn delays are applied in addition to the tick delays - summ up.
--
-- @see: http://www.renoise.com/board/index.php?showtopic=28604&view=findpost&p=224642
--
function _export_pos_to_float(pos, delay, tick, idx)
    -- Find last known tpl value
    local tpl = RNS.transport.tpl
    for i=idx,1,-1 do
        if DATA_TPL[i] ~= nil and i <= pos then
            tpl = tonumber(DATA_TPL[i], 16)
            break
        end
    end
    -- Calculate tick delay
    local float = export_tick_to_delay(tick, tpl)
    if float == false then return false end
    -- Calculate and override with global tick delay
    if DATA_TICK_DELAY[pos] ~= nil then
        local g_float = export_tick_to_delay(tonumber(DATA_TICK_DELAY[pos], 16), tpl)
        if g_float == false then return false
        else float = g_float end
    end
    -- Convert to pos
    float = float + delay / 256
    return pos + float
end

-- Create 'LPB position' table, so we can more easily
-- figure out the absolute time of any given pos
function create_lpb_lookup_table()
    if not table.is_empty(DATA_LPB) then
        local last_pos = 0
        local last_key = 0
        local last_factor = 1
        local keys = table.keys(DATA_LPB)
        table.sort(keys)
        for _,k in ipairs(keys) do
            local v = tonumber(DATA_LPB[k],16)
            local factor = 4/v
            local pos = last_pos + ((k-last_key) * last_factor)
            LPB_LOOKUP_TABLE[k] = {
                factor = factor,
                abs_pos = pos,
            }
            last_pos = pos
            last_key = k
            last_factor = factor
        end
    end
end

-- Convert pos to absolute pos that respect LPB changes,
-- using the lookup table to speed up things ..
function _resolve_abs_pos(pos)
    local lookup = nil
    local lookup_idx = nil
    for idx=pos,1,-1 do
        if LPB_LOOKUP_TABLE[idx] ~= nil then
            if (idx == pos) then
                -- Found exact match
                return LPB_LOOKUP_TABLE[idx].abs_pos
            elseif (idx < pos) then
                lookup = LPB_LOOKUP_TABLE[idx]
                lookup_idx = idx
                break
            end
        end
    end
    if lookup then
        local diff = lookup.factor * (pos-lookup_idx)
        return lookup.abs_pos + diff
    else
        -- No match, return position as-is
        return pos
    end
end

-- Return a MF2T timestamp
function _export_float_to_time(float, division, idx)
    local lpb = RNS.transport.lpb
    local abs_pos = _resolve_abs_pos(float)
    local time = (float - 1) * (division / lpb)
    return math.floor(time + .5) --Round
end

-- Note ON
function _export_note_on(tmap, sort_me, data, idx)
    -- Create MF2T message
    local pos_d = _export_pos_to_float(data.pos_start, data.delay_start,
        tonumber(data.tick_delay_start, 16), idx)
    if pos_d ~= false then
        local msg = "On ch=" .. tmap.midi_channel .. " n=" ..  data.note .. " v=" .. math.min(data.volume, 127)
        sort_me:insert{pos_d, msg, tmap.track_number}
    end
end


-- Note OFF
function _export_note_off(tmap, sort_me, data, idx)
    -- Create MF2T message
    local pos_d = _export_pos_to_float(data.pos_end, data.delay_end,
        tonumber(data.tick_delay_end, 16), idx)
    if pos_d ~= false then
        local msg = "Off ch=" .. tmap.midi_channel .. " n=" ..  data.note .. " v=0"
        sort_me:insert{pos_d, msg, tmap.track_number}
    end
end

-- Midi CC
function _export_midi_cc(tmap, sort_me, param, idx)
    -- Create MF2T message
    local cc_pos = _export_pos_to_float(param.cc_pos, 0, 0, idx)
    if cc_pos ~= false and cc_pos > 0 then
        local msg = "Par ch=" .. tmap.midi_channel .. " c=" ..  tonumber(param.cc_number,16) .. " v=" .. tonumber(param.cc_value,16)
        sort_me:insert{cc_pos, msg, tmap.track_number}
    end
end
function _export_midi_pb(tmap, sort_me, param, idx)
    -- Create MF2T message
    local cc_pos = _export_pos_to_float(param.pos, 0, 0, idx)
    if cc_pos ~= false and cc_pos > 0 then
        local msg = "Pb ch=" .. tmap.midi_channel .. " v=" .. (tonumber(param.number,16)*0.5)*0x100+(tonumber(param.value,16)*0.5)
        sort_me:insert{cc_pos, msg, tmap.track_number}
        -- also write midi pitchbend to midi cc 20
        local msg2 = "Par ch=" .. tmap.midi_channel .. " c=20" .. " v=" .. ((tonumber(param.number,16)*0.5)*0x100+(tonumber(param.value,16)*0.5))/128
        sort_me:insert{cc_pos, msg2, tmap.track_number}
    end
end
function _export_midi_chpr(tmap, sort_me, param, idx)
    -- Create MF2T message
    local cc_pos = _export_pos_to_float(param.pos, 0, 0, idx)
    if cc_pos ~= false and cc_pos > 0 then
        local msg = "ChPr ch=" .. tmap.midi_channel .. " v=" .. tonumber(param.value,16)
        sort_me:insert{cc_pos, msg, tmap.track_number}
        -- also write midi channel aftertouch to midi cc 102
        local msg2 = "Par ch=" .. tmap.midi_channel .. " c=102" .. " v=" .. tonumber(param.value,16)
        sort_me:insert{cc_pos, msg2, tmap.track_number}
    end
end

function export_midi()

    local midi = Midi()
    midi:open()
    midi:setTimebase(MIDI_DIVISION);
    midi:setBpm(RNS.transport.bpm); -- Initial BPM

    -- Debug
    --dbug("DATA"); dbug(DATA)
    --dbug("DATA_BPM"); dbug(DATA_BPM)
    --dbug("DATA_LPB"); dbug(DATA_LPB)
    --dbug("DATA_TPL"); dbug(DATA_TPL)
    --dbug("DATA_TICK_DELAY"); dbug(DATA_TICK_DELAY)
    --dbug("DATA_CC..."); dbug(DATA_CC)

    -- reusable/mutable "sort_me" table
    local sort_me = table.create()

    -- Yield every XX notes/messages to avoid timeout nag screens
    local yield_every = 250

    -- Create lookup table from DATA_LPB
    create_lpb_lookup_table()

    -- Register MIDI tracks in the 'track_map'
    -- index is renoise instr, value is {
    --  track_number = MIDI track #
    --  midi_channel = MIDI channel #
    --  }
    local track_map = {}
    local registerTrack = function(instr_idx)
        local tn = midi:newTrack()
        -- Renoise Instrument Name as MIDI TrkName
        midi:addMsg(tn,
            '0 Meta TrkName "' .. instrumentTrackNames[instr_idx] .. " (" ..
            string.format("%0.2X", instr_idx - 1) .. ": " ..
            string.gsub(RNS.instruments[instr_idx].name, '"', '') .. ')"'
        )
        -- Renoise Instrument Name as MIDI InstrName
        midi:addMsg(tn,
            '0 Meta InstrName "' ..
            string.format("%0.2X", instr_idx - 1) .. ": " ..
            string.gsub(RNS.instruments[instr_idx].name, '"', '') .. " / " .. instrumentTrackNames[instr_idx] .. '"'
        )
        track_map[instr_idx] = {
            track_number = tn,
            --midi_channel = MIDI_CHANNEL,
            midi_channel = RNS.instruments[instr_idx].midi_output_properties.channel,
        }
        return track_map[instr_idx]
    end

    -- Whenever we encounter a BPM change, write it to the MIDI tempo track
    local lpb = RNS.transport.lpb -- Initial LPB
    for pos,bpm in pairs(DATA_BPM) do
        sort_me:insert{ pos, bpm }
    end
    -- [1] = Pos, [2] = BPM
    table.sort(sort_me, export_compare)
    for i=1,#sort_me do
        local bpm = tonumber(sort_me[i][2], 16)
        if  bpm > 0 then
            local abs_pos = _resolve_abs_pos(sort_me[i][1])
            local timestamp = export_pos_to_time(abs_pos, 0, MIDI_DIVISION, lpb)
            if timestamp > 0 then
                midi:addMsg(1, timestamp .. " Tempo " .. bpm_to_tempo(bpm))
            end
        end
    end

    -- Create a new MIDI track for each Renoise Instrument
    -- reuse "sort_me" table:
    -- [1] = Pos+Delay, [2] = Msg, [3] = Track number (tmap.track_number)
    local idx = _export_max_pos(DATA_TPL) or 1
    sort_me:clear()
    for i=1,#DATA do
        if table.count(DATA[i]) > 0 then
            local tmap = registerTrack(i)
            for j=1,#DATA[i] do
                _export_note_on(tmap, sort_me, DATA[i][j], idx)
                _export_note_off(tmap, sort_me, DATA[i][j], idx)
                if (j % yield_every == 0) then
                    fancyStatus:show_status(export_status_progress())
                    if COROUTINE_MODE then coroutine.yield() end
                    dbug(("Process(midi()) Instr: %d; Note: %d."):format(i, j))
                end
            end
            export_ch_rotator()
        end
        -- Yield every instrument to avoid timeout nag screens
        fancyStatus:show_status(export_status_progress())
        if COROUTINE_MODE then coroutine.yield() end
        dbug(("Process(midi()) Instr: %d."):format(i))
    end

    -- Process MIDI Meta Messages
    for i=1,#DATA_META do
        if table.count(DATA_META[i]) > 0 then
            local tmap = track_map[i]
            if not tmap then
                tmap = registerTrack(i)
            end
            for p=1,#DATA_META[i] do
                
                sort_me:insert{DATA_META[i][p].pos, DATA_META[i][p].msg, tmap.track_number}
                if (p % yield_every == 0) then
                    fancyStatus:show_status(export_status_progress())
                    if COROUTINE_MODE then coroutine.yield() end
                    dbug(("Process(midi()) Instr: %d; META Message: %d."):format(i, p))
                end
            end
        end
    end
    
    -- Process MIDI-CC Messages
    for i=1,#DATA_CC do
        if table.count(DATA_CC[i]) > 0 then
            local tmap = track_map[i]
            if not tmap then
                tmap = registerTrack(i)
            end
            for p=1,#DATA_CC[i] do
                _export_midi_cc(tmap, sort_me, DATA_CC[i][p], idx)
                if (p % yield_every == 0) then
                    fancyStatus:show_status(export_status_progress())
                    if COROUTINE_MODE then coroutine.yield() end
                    dbug(("Process(midi()) Instr: %d; CC Message: %d."):format(i, p))
                end
            end
        end
    end
    -- Process MIDI-Pitchbend Messages
    for i=1,#DATA_PB do
        if table.count(DATA_PB[i]) > 0 then
            local tmap = track_map[i]
            if not tmap then
                tmap = registerTrack(i)
            end
            for p=1,#DATA_PB[i] do
                _export_midi_pb(tmap, sort_me, DATA_PB[i][p], idx)
                if (p % yield_every == 0) then
                    fancyStatus:show_status(export_status_progress())
                    if COROUTINE_MODE then coroutine.yield() end
                    dbug(("Process(midi()) Instr: %d; PB Message: %d."):format(i, p))
                end
            end
        end
    end
    -- Process MIDI-Channel Aftertouch Messages
    for i=1,#DATA_CHPR do
        if table.count(DATA_CHPR[i]) > 0 then
            local tmap = track_map[i]
            if not tmap then
                tmap = registerTrack(i)
            end
            for p=1,#DATA_CHPR[i] do
                _export_midi_chpr(tmap, sort_me, DATA_CHPR[i][p], idx)
                if (p % yield_every == 0) then
                    fancyStatus:show_status(export_status_progress())
                    if COROUTINE_MODE then coroutine.yield() end
                    dbug(("Process(midi()) Instr: %d; PB Message: %d."):format(i, p))
                end
            end
        end
    end

    -- reuse "sort_me" table:
    -- [1] = MF2T Timestamp, [2] = Msg, [3] = Track number (tmap.track_number)

    idx = _export_max_pos(DATA_LPB) or 1
    for j=1,#sort_me do
        sort_me[j][1] = _export_float_to_time(sort_me[j][1], MIDI_DIVISION, idx)
        if (j % yield_every == 0) then
            fancyStatus:show_status(export_status_progress())
            if COROUTINE_MODE then coroutine.yield() end
            dbug(("Process(midi()) _float_to time: %d."):format(j))
        end
    end
    table.sort(sort_me, export_compare)

    -- Meta TrkEnd
    local end_of_track = table.create()
    for i=1,#sort_me do
        midi:addMsg(sort_me[i][3], trim(sort_me[i][1] .. " " .. sort_me[i][2]))
        if (end_of_track[sort_me[i][3]] == nil or end_of_track[sort_me[i][3]] < sort_me[i][1]) then
            end_of_track[sort_me[i][3]] = sort_me[i][1]
        end
        -- Yield every 1000 messages to avoid timeout nag screens
        if (i % 1000 == 0) then
            fancyStatus:show_status(export_status_progress())
            if COROUTINE_MODE then coroutine.yield() end
            dbug(("Process(midi()) Msg: %d."):format(i))
        end
    end
    for track,timestamp in pairs(end_of_track) do
        midi:addMsg(track, trim(timestamp .. " Meta TrkEnd"))
    end

    

  
    -- Save files
    midi:saveTxtFile(FILEPATH .. '.txt')
    midi:saveMidFile(FILEPATH)

end


--------------------------------------------------------------------------------
-- Main procedure(s) wraped in ProcessSlicer
--------------------------------------------------------------------------------

function export_procedure(plan)
    FILEPATH = renoise.app():prompt_for_filename_to_write("mid", "Export MIDI")
    if FILEPATH == '' then return end

    RNS = renoise.song()
    fancyStatus = FancyStatusMessage()
    if COROUTINE_MODE then
        local process = ProcessSlicer(function() export_build(plan) end, export_done)
        renoise.tool().app_release_document_observable
            :add_notifier(function()
                if (process and process:running()) then
                    process:stop()
                    dbug("Process 'build_data()' has been aborted due to song change.")
                end
            end)
        process:start()
    else
        export_build(plan)
        export_done()
    end
end


function export_build(plan)
    fancyStatus:show_status(export_status_progress())
    export_build_data(plan)
    export_midi()
end


function export_done()
    fancyStatus:show_status("MIDI Export, Done!")
end

