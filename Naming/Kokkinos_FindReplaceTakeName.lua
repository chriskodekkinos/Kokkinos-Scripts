-- @description Find and Replace Take Names
-- @author Cookie (Chris Kokkinos)
-- @version 1.0.0
-- @changelog
--   - Initial release
-- @about
--   # Find and Replace Take Names
--
--   Batch find-and-replace text in the take names of selected media items.
--
--   ## Usage
--   1. Select one or more media items
--   2. Run this script
--   3. Enter the text to find and the replacement text
--   4. Click Replace to apply
--   5. Select new items and repeat as needed
--
--   ## Requirements
--   - ReaImGui
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui is required.", "Error", 0)
    return
end

local ctx = reaper.ImGui_CreateContext("Find and Replace Take Names")
local find_text, replace_text = "", ""
local result_msg = ""
local result_color = 0x888888FF

local function do_replace()
    if find_text == "" then
        result_msg = "Find field is empty"
        result_color = 0xFF4444FF
        return
    end

    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then
        result_msg = "No items selected"
        result_color = 0xFF4444FF
        return
    end

    local pattern = find_text:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    local safe_rep = replace_text:gsub("%%", "%%%%")

    reaper.Undo_BeginBlock()
    local renamed = 0
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take then
            local name = reaper.GetTakeName(take)
            if name:find(find_text, 1, true) then
                local new_name = name:gsub(pattern, safe_rep)
                reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
                renamed = renamed + 1
            end
        end
    end
    reaper.Undo_EndBlock("Find and Replace Take Names", -1)
    reaper.UpdateArrange()

    if renamed > 0 then
        result_msg = "Renamed " .. renamed .. " item" .. (renamed > 1 and "s" or "")
        result_color = 0x44FF44FF
    else
        result_msg = "No matches found in " .. count .. " item" .. (count > 1 and "s" or "")
        result_color = 0xFFCC00FF
    end
end

local function loop()
    reaper.ImGui_SetNextWindowSize(ctx, 340, 0)
    local visible, open = reaper.ImGui_Begin(ctx, "Find and Replace Take Names", true,
        reaper.ImGui_WindowFlags_NoCollapse() + reaper.ImGui_WindowFlags_AlwaysAutoResize())

    if visible then
        local count = reaper.CountSelectedMediaItems(0)
        reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, count .. " item" .. (count ~= 1 and "s" or "") .. " selected")
        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_Text(ctx, "Find:")
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        _, find_text = reaper.ImGui_InputText(ctx, "##find", find_text)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Text(ctx, "Replace:")
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        _, replace_text = reaper.ImGui_InputText(ctx, "##replace", replace_text)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Spacing(ctx)

        if reaper.ImGui_Button(ctx, "Replace", -1, 0) then
            do_replace()
        end

        if result_msg ~= "" then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_TextColored(ctx, result_color, result_msg)
        end

        reaper.ImGui_End(ctx)
    end

    if open then reaper.defer(loop) end
end

loop()
