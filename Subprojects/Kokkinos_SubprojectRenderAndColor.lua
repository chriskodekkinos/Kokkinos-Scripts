-- @description Subproject Render and Color
-- @author Cookie (Chris Kokkinos)
-- @version 1.2.0
-- @changelog
--   v1.2.0
--     - Fix false matches on similarly-named subprojects (exact basename matching)
--   v1.1.0
--     - Find unsaved parent projects by checking items in memory (no .rpp file needed)
--   v1.0.0
--     - Initial release
-- @about
--   # Subproject Render and Color
--
--   Saves and renders the current subproject, then navigates to the parent
--   project to color the rendered subproject item with the "needs export"
--   color, and returns to the subproject.
--
--   ## Usage
--   1. Work in a subproject
--   2. Run this script (replaces your usual save/render hotkey)
--   3. The subproject is saved and rendered
--   4. The rendered item in the parent project is colored
--   5. You're returned to the subproject
--
--   ## Notes
--   - Requires SWS Extension
--   - Shares the "needs export" color with Kokkinos_MarkItemNeedsExport
--   - Automatically mutes video track sends before render
--   - Matches the parent item by .rpp source filename (safe with renamed takes)
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts

-----------------------------------------------------------
-- Validation
-----------------------------------------------------------

local current_proj = reaper.EnumProjects(-1)
local current_proj_name = reaper.GetProjectName(0)

if not current_proj_name or current_proj_name == "" then
    reaper.ShowMessageBox("No project is open.", "Error", 0)
    return
end

-----------------------------------------------------------
-- Export color (shared with Kokkinos_MarkItemNeedsExport)
-----------------------------------------------------------

local EXT_SECTION = "Kokkinos_ExportStatus"
local EXT_KEY = "needs_export_color"
local DEFAULT_COLOR = "#FF6600"

local function hex_to_reaper_color(hex)
    hex = hex:gsub("#", "")
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not r or not g or not b then return nil end
    return reaper.ColorToNative(r, g, b) | 0x1000000
end

local function get_color()
    local stored = reaper.GetExtState(EXT_SECTION, EXT_KEY)
    if stored ~= "" then
        local color = hex_to_reaper_color(stored)
        if color then return color end
    end
    reaper.SetExtState(EXT_SECTION, EXT_KEY, DEFAULT_COLOR, true)
    return hex_to_reaper_color(DEFAULT_COLOR)
end

-----------------------------------------------------------
-- Video track muting (same pattern as SPS script)
-----------------------------------------------------------

local function disable_video_sends()
    local track_states = {}
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(track)
        if name:lower():find("video", 1, true) then
            local was_enabled = reaper.GetMediaTrackInfo_Value(track, "B_MAINSEND")
            track_states[track] = was_enabled
            reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
        end
    end
    return track_states
end

local function restore_video_sends(track_states)
    for track, was_enabled in pairs(track_states) do
        if was_enabled == 1 then
            reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", 1)
        end
    end
end

-----------------------------------------------------------
-- Helpers
-----------------------------------------------------------

local function basename(path)
    return path:match("[/\\]([^/\\]+)$") or path
end

-----------------------------------------------------------
-- Parent project navigation
-----------------------------------------------------------

local function find_parent_project(subproj_name)
    local subproj_lower = subproj_name:lower()
    local current_proj = reaper.EnumProjects(-1)
    local proj_idx = 0

    -- Match the subproject name as a whole word in file contents
    -- (surrounded by non-alphanumeric/underscore chars or start/end of string)
    local escaped = subproj_lower:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    local boundary_pattern = "[^%w_]" .. escaped .. "[^%w_]"

    while true do
        local proj, proj_fn = reaper.EnumProjects(proj_idx)
        if not proj then break end

        if proj ~= current_proj then
            if proj_fn ~= "" then
                -- Saved project: search file contents on disk
                local file = io.open(proj_fn, "r")
                if file then
                    local contents = file:read("*all")
                    file:close()
                    local lower_contents = contents:lower()
                    -- Pad with spaces so boundary pattern works at start/end
                    if (" " .. lower_contents .. " "):find(boundary_pattern) then
                        return proj
                    end
                end
            else
                -- Unsaved project: check items in memory by source filename
                local found = false
                for i = 0, reaper.CountMediaItems(proj) - 1 do
                    local item = reaper.GetMediaItem(proj, i)
                    for j = 0, reaper.CountTakes(item) - 1 do
                        local take = reaper.GetTake(item, j)
                        local source = reaper.GetMediaItemTake_Source(take)
                        local filename = reaper.GetMediaSourceFileName(source)
                        local base = basename(filename):lower()
                        if base == subproj_lower
                        or base == subproj_lower .. ".rpp" then
                            found = true
                            break
                        end
                    end
                    if found then break end
                end
                if found then return proj end
            end
        end
        proj_idx = proj_idx + 1
    end
    return nil
end

-----------------------------------------------------------
-- Find subproject item in parent by .rpp source filename
-----------------------------------------------------------

local function find_subproject_items(proj, subproj_name)
    local subproj_lower = subproj_name:lower()
    local items = {}

    local item_count = reaper.CountMediaItems(proj)
    for i = 0, item_count - 1 do
        local item = reaper.GetMediaItem(proj, i)
        local take_count = reaper.CountTakes(item)

        for j = 0, take_count - 1 do
            local take = reaper.GetTake(item, j)
            local source = reaper.GetMediaItemTake_Source(take)
            local filename = reaper.GetMediaSourceFileName(source)
            local base = basename(filename):lower()

            if base == subproj_lower
            or base == subproj_lower .. ".rpp" then
                items[#items + 1] = item
                break
            end
        end
    end
    return items
end

-----------------------------------------------------------
-- Main
-----------------------------------------------------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- 1. Disable video track sends
local track_states = disable_video_sends()

-- 2. Save and render RPP-PROX
reaper.Main_OnCommand(42332, 0)

-- 3. Restore video track sends
restore_video_sends(track_states)

-- 4. Find and switch to parent project
local parent = find_parent_project(current_proj_name)

if parent then
    local color = get_color()
    reaper.SelectProjectInstance(parent)

    -- 5. Find and color the subproject item(s)
    local items = find_subproject_items(parent, current_proj_name)
    for _, item in ipairs(items) do
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)
    end

    reaper.UpdateArrange()

    -- 6. Return to subproject
    reaper.SelectProjectInstance(current_proj)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Subproject render and color", -1)
