-- @description Batch Rename and Enumerate
-- @author Cookie (Chris Kokkinos)
-- @version 1.1.0
-- @changelog
--   v1.1.0
--     - Strip .rpp suffix from auto-detected base name (subproject renders)
--   v1.0.0
--     - Initial release
-- @about
--   # Batch Rename and Enumerate
--
--   Micro-renamer for quickly applying a base name with sequential numbering
--   to selected media items. Ideal for enumerating sound variations.
--
--   ## Usage
--   1. Select one or more media items
--   2. Run this script
--   3. The base name is auto-detected from the first selected item
--   4. Adjust base name, separator, start number, and padding as needed
--   5. Review the live preview, then click Apply
--
--   ## Requirements
--   - ReaImGui
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts

if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui is required.", "Error", 0)
    return
end

local ctx = reaper.ImGui_CreateContext("Batch Rename and Enumerate")

local base_name = ""
local separator = "_"
local start_num = 1
local padding   = 2
local result_msg   = ""
local result_color = 0x888888FF
local last_first_item = nil

-----------------------------------------------------------
-- Auto-detection: strip trailing separator + digits
-----------------------------------------------------------

local function parse_name(name)
    for _, sep in ipairs({"_", "-", "."}) do
        local esc = sep:gsub("(%W)", "%%%1")
        local base, num = name:match("^(.+)" .. esc .. "(%d+)$")
        if base then
            return base, sep, tonumber(num), #num
        end
    end
    return name, "_", 1, 2
end

-----------------------------------------------------------
-- Generate name for a given index
-----------------------------------------------------------

local function make_name(i)
    local fmt = "%s%s%0" .. padding .. "d"
    return string.format(fmt, base_name, separator, start_num + i)
end

-----------------------------------------------------------
-- Apply rename to all selected items
-----------------------------------------------------------

local function do_apply()
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then
        result_msg = "No items selected"
        result_color = 0xFF4444FF
        return
    end
    if base_name == "" then
        result_msg = "Base name is empty"
        result_color = 0xFF4444FF
        return
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local renamed = 0
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take then
            local new_name = make_name(i)
            reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
            renamed = renamed + 1
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Batch Rename & Enumerate", -1)

    if renamed > 0 then
        result_msg = "Renamed " .. renamed .. " item" .. (renamed > 1 and "s" or "")
        result_color = 0x44FF44FF
    else
        result_msg = "No active takes found"
        result_color = 0xFFCC00FF
    end
end

-----------------------------------------------------------
-- Check selection and auto-detect on change
-----------------------------------------------------------

local function check_selection()
    local count = reaper.CountSelectedMediaItems(0)
    if count == 0 then
        if last_first_item ~= nil then
            last_first_item = nil
            base_name = ""
            separator = "_"
            start_num = 1
            padding   = 2
        end
        return
    end

    local first = reaper.GetSelectedMediaItem(0, 0)
    if first == last_first_item then return end

    last_first_item = first
    local take = reaper.GetActiveTake(first)
    if take then
        local name = reaper.GetTakeName(take)
        name = name:gsub("%.[Rr][Pp][Pp]$", "")
        base_name, separator, start_num, padding = parse_name(name)
    else
        base_name = ""
        separator = "_"
        start_num = 1
        padding   = 2
    end
    result_msg = ""
end

-----------------------------------------------------------
-- Main UI loop
-----------------------------------------------------------

local function loop()
    check_selection()

    reaper.ImGui_SetNextWindowSize(ctx, 360, 0)
    local visible, open = reaper.ImGui_Begin(ctx, "Batch Rename & Enumerate", true,
        reaper.ImGui_WindowFlags_NoCollapse() + reaper.ImGui_WindowFlags_AlwaysAutoResize())

    if visible then
        local count = reaper.CountSelectedMediaItems(0)
        reaper.ImGui_TextColored(ctx, 0xAAAAAAFF,
            count .. " item" .. (count ~= 1 and "s" or "") .. " selected")
        reaper.ImGui_Spacing(ctx)

        -- Base Name
        reaper.ImGui_Text(ctx, "Base Name:")
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        _, base_name = reaper.ImGui_InputText(ctx, "##base", base_name)

        reaper.ImGui_Spacing(ctx)

        -- Separator / Start / Padding on one row
        local avail = reaper.ImGui_GetContentRegionAvail(ctx)
        local sep_w = 60
        local num_w = (avail - sep_w - 16) / 2  -- 16 = spacing between 3 widgets

        reaper.ImGui_Text(ctx, "Separator")
        reaper.ImGui_SameLine(ctx, 0, sep_w + 12)
        reaper.ImGui_Text(ctx, "Start")
        reaper.ImGui_SameLine(ctx, 0, num_w - 16)
        reaper.ImGui_Text(ctx, "Padding")

        reaper.ImGui_SetNextItemWidth(ctx, sep_w)
        _, separator = reaper.ImGui_InputText(ctx, "##sep", separator)

        reaper.ImGui_SameLine(ctx, 0, 8)
        reaper.ImGui_SetNextItemWidth(ctx, num_w)
        local changed_s
        changed_s, start_num = reaper.ImGui_InputInt(ctx, "##start", start_num)
        if start_num < 0 then start_num = 0 end

        reaper.ImGui_SameLine(ctx, 0, 8)
        reaper.ImGui_SetNextItemWidth(ctx, num_w)
        local changed_p
        changed_p, padding = reaper.ImGui_InputInt(ctx, "##pad", padding)
        if padding < 1 then padding = 1 end
        if padding > 5 then padding = 5 end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Spacing(ctx)

        -- Live Preview
        if count > 0 and base_name ~= "" then
            reaper.ImGui_Text(ctx, "Preview:")
            local preview_h = math.min(count, 10) * reaper.ImGui_GetTextLineHeightWithSpacing(ctx) + 8
            reaper.ImGui_BeginChild(ctx, "##preview", -1, preview_h, reaper.ImGui_ChildFlags_Borders())
            for i = 0, math.min(count - 1, 9) do
                reaper.ImGui_TextColored(ctx, 0x88CCFFFF, string.format("%d. %s", i + 1, make_name(i)))
            end
            if count > 10 then
                reaper.ImGui_TextColored(ctx, 0x888888FF, string.format("  ... and %d more", count - 10))
            end
            reaper.ImGui_EndChild(ctx)
            reaper.ImGui_Spacing(ctx)
        end

        -- Apply button
        if reaper.ImGui_Button(ctx, "Apply", -1, 0) then
            do_apply()
        end

        -- Result message
        if result_msg ~= "" then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_TextColored(ctx, result_color, result_msg)
        end

        reaper.ImGui_End(ctx)
    end

    if open then reaper.defer(loop) end
end

loop()
