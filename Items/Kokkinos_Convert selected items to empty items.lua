-- @description Convert selected items to empty items
-- @author Kokkinos
-- @version 1.0
-- @about
--   Removes all takes from selected items, converting them to empty items.
--   Preserves item position, length, track, and color.
--
--   Special thanks to Rodrigo Robinet for the request.

local item_count = reaper.CountSelectedMediaItems(0)
if item_count == 0 then return end

-- Store item properties before deleting
local item_data = {}
for i = 0, item_count - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  item_data[#item_data + 1] = {
    track = reaper.GetMediaItemTrack(item),
    pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    color = reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR"),
  }
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Delete original items (iterate in reverse to keep indices valid)
for i = item_count - 1, 0, -1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local track = reaper.GetMediaItemTrack(item)
  reaper.DeleteTrackMediaItem(track, item)
end

-- Create new empty items with the same properties
for _, data in ipairs(item_data) do
  local new_item = reaper.AddMediaItemToTrack(data.track)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", data.pos)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", data.len)
  if data.color ~= 0 then
    reaper.SetMediaItemInfo_Value(new_item, "I_CUSTOMCOLOR", data.color)
  end
  reaper.SetMediaItemSelected(new_item, true)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Convert selected items to empty items", -1)
