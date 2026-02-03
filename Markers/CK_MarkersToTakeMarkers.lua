-- @description Markers to Take Markers
-- @author Cookie (Chris Kokkinos)
-- @version 1.1.0
-- @changelog
--   - Support multiple selected items
-- @about
--   # Markers to Take Markers
--
--   Copies project markers that fall within selected media items' time ranges
--   and applies them as take markers on each item's active take, preserving
--   marker names and colors.
--
--   ## Usage
--   1. Place project markers on the timeline with descriptive names
--   2. Select one or more media items
--   3. Run this script
--   4. A dialog will ask whether to remove the original project markers
--
--   ## Notes
--   - Only markers within each item's time range are copied
--   - Accounts for take start offset and playrate per item
--   - Works with multiple selected items at once
--   - Requires REAPER v5.20+ (SetTakeMarker API)
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts

-----------------------------------------------------------
-- Validation
-----------------------------------------------------------

if not reaper.SetTakeMarker then
    reaper.ShowMessageBox("This script requires REAPER v5.20 or later.", "Error", 0)
    return
end

local item_count = reaper.CountSelectedMediaItems(0)
if item_count == 0 then
    reaper.ShowMessageBox("Please select one or more media items.", "No items selected", 0)
    return
end

-----------------------------------------------------------
-- Collect all project markers
-----------------------------------------------------------

local proj_markers = {}
local total = reaper.CountProjectMarkers(0)

for i = 0, total - 1 do
    local retval, is_region, pos, _, name, idx, color = reaper.EnumProjectMarkers3(0, i)
    if retval > 0 and not is_region then
        proj_markers[#proj_markers + 1] = {
            pos = pos,
            name = name,
            color = color,
            marker_num = idx,
        }
    end
end

if #proj_markers == 0 then
    reaper.ShowMessageBox("No project markers found.", "Nothing to do", 0)
    return
end

-----------------------------------------------------------
-- Process each selected item
-----------------------------------------------------------

local total_applied = 0
local used_markers = {}

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

for i = 0, item_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)

    if take then
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

        for _, m in ipairs(proj_markers) do
            if m.pos >= item_pos and m.pos <= item_end then
                local take_pos = (m.pos - item_pos) * playrate + start_offs
                if m.color ~= 0 then
                    reaper.SetTakeMarker(take, -1, m.name, take_pos, m.color)
                else
                    reaper.SetTakeMarker(take, -1, m.name, take_pos)
                end
                total_applied = total_applied + 1
                used_markers[m.marker_num] = true
            end
        end
    end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

if total_applied == 0 then
    reaper.Undo_EndBlock("Markers to Take Markers", -1)
    reaper.ShowMessageBox(
        "No project markers found within any selected item's time range.",
        "Nothing to do", 0)
    return
end

-----------------------------------------------------------
-- Optional: remove original project markers
-----------------------------------------------------------

local response = reaper.ShowMessageBox(
    total_applied .. " take marker(s) applied.\n\nRemove the original project markers?",
    "Markers to Take Markers", 4)

if response == 6 then
    reaper.PreventUIRefresh(1)
    for marker_num in pairs(used_markers) do
        reaper.DeleteProjectMarker(0, marker_num, false)
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
end

reaper.Undo_EndBlock("Markers to Take Markers", -1)
