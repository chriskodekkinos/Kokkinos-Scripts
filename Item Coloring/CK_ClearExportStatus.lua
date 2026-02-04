-- @description Clear Export Status
-- @author Cookie (Chris Kokkinos)
-- @version 1.0.0
-- @changelog
--   - Initial release
-- @about
--   # Clear Export Status
--
--   Resets selected media items' custom color, restoring them to their
--   parent track's color. Use this after exporting items to clear the
--   "needs export" visual flag.
--
--   ## Usage
--   1. Select one or more media items that have been exported
--   2. Run this script
--   3. Item colors are reset to match their track
--
--   ## Notes
--   - Companion script to "Mark Item Needs Export"
--   - Sets item color to 0 (inherit from track)
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts

local item_count = reaper.CountSelectedMediaItems(0)
if item_count == 0 then
    reaper.ShowMessageBox("Please select one or more media items.", "No items selected", 0)
    return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

for i = 0, item_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", 0)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Clear export status", -1)
