-- @description Focus Timer
-- @author Cookie (Chris Kokkinos)
-- @version 1.1.0
-- @changelog
--   v1.1.0 - Structured Project / Category / Task hierarchy, rename/merge, decimal idle
--   v1.0.0 - Initial release
-- @about
--   Dockable focus timer with task-based session logging.
--   Set a target duration, watch the color shift as you progress
--   (green -> yellow -> orange -> red overtime), and log time against
--   Project / Category / Task records that accumulate across sessions.
--   Requires: ReaImGui
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts
-- @provides [main] .

------------------------------------------------------------------------
-- Extension check
------------------------------------------------------------------------
if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("This script requires ReaImGui.", "Focus Timer", 0)
    return
end

------------------------------------------------------------------------
-- Persistence
------------------------------------------------------------------------
local DATA_DIR  = reaper.GetResourcePath() .. "/Data"
local DATA_FILE = DATA_DIR .. "/Kokkinos_FocusTimer_tasks.lua"

-- tasks is a list of records:
--   { project, category, name, total, sessions = { {date, ts, planned, actual}, ... } }
local tasks = {}

local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local lines = { "{" }
        local next_indent = indent .. "  "
        local is_array = (#val > 0)
        if is_array then
            for _, v in ipairs(val) do
                lines[#lines + 1] = next_indent .. serialize(v, next_indent) .. ","
            end
        else
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                local key_str
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_str = k
                else
                    key_str = "[" .. string.format("%q", tostring(k)) .. "]"
                end
                lines[#lines + 1] = next_indent .. key_str .. " = " .. serialize(val[k], next_indent) .. ","
            end
        end
        lines[#lines + 1] = indent .. "}"
        return table.concat(lines, "\n")
    end
    return "nil"
end

local function save_tasks()
    reaper.RecursiveCreateDirectory(DATA_DIR, 0)
    local f = io.open(DATA_FILE, "w")
    if not f then return end
    f:write("return " .. serialize(tasks))
    f:close()
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Migrate legacy dict-keyed tasks ({ ["proj / task"] = { total, sessions } })
-- into the new list form with project/category/name fields.
local function migrate_if_needed(loaded)
    if type(loaded) ~= "table" then return {} end
    if loaded[1] ~= nil or next(loaded) == nil then
        -- already an array (new format), or empty
        return loaded
    end
    local list = {}
    for key, rec in pairs(loaded) do
        local parts = {}
        for p in string.gmatch(key, "[^/]+") do parts[#parts + 1] = trim(p) end
        local project, category, name = "", "", ""
        if #parts >= 3 then
            project, category, name = parts[1], parts[2], table.concat(parts, " / ", 3)
        elseif #parts == 2 then
            project, name = parts[1], parts[2]
        else
            name = parts[1] or tostring(key)
        end
        list[#list + 1] = {
            project  = project,
            category = category,
            name     = name,
            total    = rec.total or 0,
            sessions = rec.sessions or {},
        }
    end
    return list
end

local function load_tasks()
    local f = io.open(DATA_FILE, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local chunk = load(content)
    if not chunk then return end
    local ok, result = pcall(chunk)
    if ok and type(result) == "table" then
        tasks = migrate_if_needed(result)
    end
end

load_tasks()

------------------------------------------------------------------------
-- Task record helpers
------------------------------------------------------------------------
local function find_task(project, category, name)
    for _, t in ipairs(tasks) do
        if t.project == project and t.category == category and t.name == name then
            return t
        end
    end
end

local function get_or_create_task(project, category, name)
    local t = find_task(project, category, name)
    if t then return t end
    t = { project = project, category = category, name = name, total = 0, sessions = {} }
    tasks[#tasks + 1] = t
    return t
end

local function delete_task(target)
    for i, t in ipairs(tasks) do
        if t == target then
            table.remove(tasks, i)
            save_tasks()
            return
        end
    end
end

local function merge_or_rename(target, new_project, new_category, new_name)
    if new_name == "" then return end
    -- check for an existing different record with the new identity
    local existing
    for _, t in ipairs(tasks) do
        if t ~= target and t.project == new_project and t.category == new_category and t.name == new_name then
            existing = t
            break
        end
    end
    if existing then
        existing.total = (existing.total or 0) + (target.total or 0)
        for _, s in ipairs(target.sessions) do
            existing.sessions[#existing.sessions + 1] = s
        end
        for i, t in ipairs(tasks) do
            if t == target then table.remove(tasks, i) break end
        end
    else
        target.project  = new_project
        target.category = new_category
        target.name     = new_name
    end
    save_tasks()
end

local function unique_sorted(get_field, filter_fn)
    local set, list = {}, {}
    for _, t in ipairs(tasks) do
        if (not filter_fn) or filter_fn(t) then
            local v = get_field(t)
            if v ~= "" and not set[v] then
                set[v] = true
                list[#list + 1] = v
            end
        end
    end
    table.sort(list)
    return list
end

local function unique_projects()
    return unique_sorted(function(t) return t.project end)
end

local function unique_categories_for(project)
    return unique_sorted(
        function(t) return t.category end,
        function(t) return project == "" or t.project == project end
    )
end

local function tasks_matching(project, category)
    local list = {}
    for _, t in ipairs(tasks) do
        if (project == "" or t.project == project) and
           (category == "" or t.category == category) then
            list[#list + 1] = t
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

------------------------------------------------------------------------
-- Timer state
------------------------------------------------------------------------
local SCRIPT_START_TS = os.time()
local EXT_SECTION = "Kokkinos_FocusTimer"

local function load_setting(key, default)
    local v = reaper.GetExtState(EXT_SECTION, key)
    if v == "" then return default end
    return v
end

local state = {
    project_label     = "",
    category_label    = "",
    task_label        = "",
    planned_hours     = 0,
    planned_minutes   = 45,
    running           = false,
    session_start     = 0,
    session_banked    = 0,
    idle_enabled      = load_setting("idle_enabled", "1") == "1",
    idle_minutes      = tonumber(load_setting("idle_minutes", "1.5")) or 1.5,
    skip_no_task_warn = load_setting("skip_no_task_warn", "0") == "1",
    last_activity_ts  = os.time(),
    last_mouse_x      = -1,
    last_mouse_y      = -1,
    last_proj_count   = reaper.GetProjectStateChangeCount(0),
    auto_paused       = false,
    paused_prompted   = false,
    paused_at         = 0,
    resume_popup_done = false,
    pending_no_task_start = false,
}

local function save_settings()
    reaper.SetExtState(EXT_SECTION, "idle_enabled", state.idle_enabled and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "idle_minutes", tostring(state.idle_minutes), true)
    reaper.SetExtState(EXT_SECTION, "skip_no_task_warn", state.skip_no_task_warn and "1" or "0", true)
end

local function planned_seconds()
    return state.planned_hours * 3600 + state.planned_minutes * 60
end

local function session_elapsed()
    if state.running then
        return state.session_banked + (os.time() - state.session_start)
    end
    return state.session_banked
end

local function format_hms(sec)
    sec = math.max(0, math.floor(sec))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

local function start_timer()
    if state.running then return end
    state.running = true
    state.session_start = os.time()
    state.last_activity_ts = os.time()
    state.auto_paused = false
    state.paused_prompted = false
    state.paused_at = 0
    state.resume_popup_done = false
end

local function pause_timer()
    if not state.running then return end
    state.session_banked = state.session_banked + (os.time() - state.session_start)
    state.running = false
    state.paused_prompted = true   -- suppress immediate prompt for manual pause
    state.paused_at = os.time()
    state.resume_popup_done = false
end

local function reset_session()
    state.running = false
    state.session_banked = 0
    state.session_start = 0
    state.auto_paused = false
    state.paused_prompted = false
    state.paused_at = 0
    state.resume_popup_done = false
end

local function check_idle()
    local mx, my = reaper.GetMousePosition()
    local pc = reaper.GetProjectStateChangeCount(0)
    local moved = (mx ~= state.last_mouse_x) or (my ~= state.last_mouse_y)
    local acted = (pc ~= state.last_proj_count)
    if moved or acted then
        state.last_activity_ts = os.time()
        state.last_mouse_x, state.last_mouse_y = mx, my
        state.last_proj_count = pc
        -- Unlock the resume prompt if paused, grace elapsed, and not already shown
        if not state.running and state.session_banked > 0
           and state.paused_prompted and not state.resume_popup_done then
            local grace = state.auto_paused and 0 or 5
            if (os.time() - (state.paused_at or 0)) >= grace then
                state.paused_prompted = false
            end
        end
    end
    if state.idle_enabled and state.running then
        local idle_for = os.time() - state.last_activity_ts
        if idle_for >= math.floor(state.idle_minutes * 60 + 0.5) then
            state.session_banked = state.session_banked + (os.time() - state.session_start)
            state.running = false
            state.auto_paused = true
            state.paused_prompted = true   -- wait for activity to unlock it (grace = 0)
            state.paused_at = os.time()
        end
    end
end

local function log_session()
    local name = trim(state.task_label)
    if name == "" then return end
    local elapsed = session_elapsed()
    if elapsed <= 0 then return end
    local t = get_or_create_task(trim(state.project_label), trim(state.category_label), name)
    t.total = (t.total or 0) + elapsed
    t.sessions[#t.sessions + 1] = {
        date    = os.date("%Y-%m-%d %H:%M"),
        ts      = os.time(),
        planned = planned_seconds(),
        actual  = elapsed,
    }
    save_tasks()
    reset_session()
end

------------------------------------------------------------------------
-- Colors
------------------------------------------------------------------------
local function progress_color()
    local planned = planned_seconds()
    if planned <= 0 then return 0x3A3A3AFF, 0xE0E0E0FF end
    local ratio = session_elapsed() / planned
    if ratio < 0.50 then return 0x1F6B3AFF, 0xE8F5E9FF
    elseif ratio < 0.80 then return 0xB89722FF, 0xFFF8E1FF
    elseif ratio < 1.00 then return 0xCC6A1FFF, 0xFFE0B2FF
    else return 0xB71C1CFF, 0xFFEBEEFF end
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local ctx = reaper.ImGui_CreateContext('Focus Timer')
local big_font = reaper.ImGui_CreateFont('sans-serif', 40)
local med_font = reaper.ImGui_CreateFont('sans-serif', 16)
reaper.ImGui_Attach(ctx, big_font)
reaper.ImGui_Attach(ctx, med_font)

local function draw_settings()
    if not reaper.ImGui_CollapsingHeader(ctx, "Settings") then return end
    local chg, new_en = reaper.ImGui_Checkbox(ctx, "Auto-pause when idle", state.idle_enabled)
    if chg then state.idle_enabled = new_en; save_settings() end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 60)
    local chg2, new_m = reaper.ImGui_InputDouble(ctx, "min##idle", state.idle_minutes, 0, 0, "%.2f")
    if chg2 then
        state.idle_minutes = math.max(0.1, math.min(120, new_m))
        save_settings()
    end
    reaper.ImGui_Text(ctx, "(activity = mouse move or any REAPER action)")
    local chk3, new_skip = reaper.ImGui_Checkbox(ctx, "Skip 'no task' warning on start", state.skip_no_task_warn)
    if chk3 then state.skip_no_task_warn = new_skip; save_settings() end
end

local function pick_dropdown(popup_id, items, on_pick, include_none)
    if reaper.ImGui_BeginPopup(ctx, popup_id) then
        if #items == 0 and not include_none then
            reaper.ImGui_Text(ctx, "(nothing yet)")
        else
            if include_none and reaper.ImGui_Selectable(ctx, "(none)") then
                on_pick("")
            end
            for _, item in ipairs(items) do
                if reaper.ImGui_Selectable(ctx, item) then on_pick(item) end
            end
        end
        reaper.ImGui_EndPopup(ctx)
    end
end

local function draw_labeled_input(label, value, popup_id)
    reaper.ImGui_Text(ctx, label)
    reaper.ImGui_SetNextItemWidth(ctx, -60)
    local changed, new_val = reaper.ImGui_InputText(ctx, "##" .. label, value)
    reaper.ImGui_SameLine(ctx)
    local clicked = reaper.ImGui_Button(ctx, "Pick##" .. label, 50, 0)
    if clicked then reaper.ImGui_OpenPopup(ctx, popup_id) end
    return changed and new_val or value
end

local function draw_task_input()
    state.project_label = draw_labeled_input("Project", state.project_label, "pick_project")
    pick_dropdown("pick_project", unique_projects(),
        function(v) state.project_label = v end, true)

    state.category_label = draw_labeled_input("Category", state.category_label, "pick_category")
    pick_dropdown("pick_category", unique_categories_for(trim(state.project_label)),
        function(v) state.category_label = v end, true)

    state.task_label = draw_labeled_input("Task", state.task_label, "pick_task")
    if reaper.ImGui_BeginPopup(ctx, "pick_task") then
        local matches = tasks_matching(trim(state.project_label), trim(state.category_label))
        if #matches == 0 then
            reaper.ImGui_Text(ctx, "(no tasks match)")
        else
            for _, t in ipairs(matches) do
                local label = t.name .. "  [" .. format_hms(t.total or 0) .. "]"
                if reaper.ImGui_Selectable(ctx, label) then
                    state.project_label  = t.project
                    state.category_label = t.category
                    state.task_label     = t.name
                end
            end
        end
        reaper.ImGui_EndPopup(ctx)
    end
end

local function center_cursor(avail, content_w)
    reaper.ImGui_SetCursorPosX(ctx, math.max(0, (avail - content_w) * 0.5))
end

local function draw_planned_inputs()
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local style_gap = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())

    -- "Target Estimate" label centered
    local lbl = "Target Estimate"
    center_cursor(avail, reaper.ImGui_CalcTextSize(ctx, lbl))
    reaper.ImGui_Text(ctx, lbl)

    -- h/m inputs row, always centered
    local inputs_w = 60 + style_gap + 60
    center_cursor(avail, inputs_w)
    reaper.ImGui_SetNextItemWidth(ctx, 60)
    local chg_h, new_h = reaper.ImGui_InputInt(ctx, "h##hrs", state.planned_hours, 0, 0)
    if chg_h then state.planned_hours = math.max(0, math.min(23, new_h)) end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 60)
    local chg_m, new_m = reaper.ImGui_InputInt(ctx, "m##mins", state.planned_minutes, 0, 0)
    if chg_m then state.planned_minutes = math.max(0, math.min(59, new_m)) end

    -- Preset buttons on their own centered row
    local preset_btn = 32
    local presets_w = preset_btn * 4 + style_gap * 3
    center_cursor(avail, presets_w)
    if reaper.ImGui_Button(ctx, "25", preset_btn, 0) then state.planned_hours, state.planned_minutes = 0, 25 end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "45", preset_btn, 0) then state.planned_hours, state.planned_minutes = 0, 45 end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "60", preset_btn, 0) then state.planned_hours, state.planned_minutes = 1, 0 end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "90", preset_btn, 0) then state.planned_hours, state.planned_minutes = 1, 30 end
end

local function draw_big_timer()
    local bg, fg = progress_color()
    local elapsed = session_elapsed()
    local planned = planned_seconds()
    local remaining = planned - elapsed
    local display, sub_display
    local is_paused = (not state.running) and state.session_banked > 0

    if is_paused then
        bg = 0x2C4A7CFF
        fg = 0xBBDEFBFF
        display = "PAUSED"
        sub_display = format_hms(elapsed) .. " elapsed"
    elseif planned > 0 and remaining >= 0 then
        display = format_hms(remaining)
        sub_display = "remaining of " .. format_hms(planned)
    elseif planned > 0 then
        display = "+" .. format_hms(-remaining)
        sub_display = "over target (" .. format_hms(planned) .. ")"
    else
        display = format_hms(elapsed)
        sub_display = "no target set"
    end

    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    if avail_w < 40 then avail_w = 40 end
    local box_h = 100

    -- Draw colored background rect directly via DrawList (no BeginChild).
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + box_h, bg, 4)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), fg)

    reaper.ImGui_PushFont(ctx, big_font, 40)
    local tw = reaper.ImGui_CalcTextSize(ctx, display)
    reaper.ImGui_SetCursorScreenPos(ctx, cx + math.max(0, (avail_w - tw) * 0.5), cy + 4)
    reaper.ImGui_Text(ctx, display)
    reaper.ImGui_PopFont(ctx)

    reaper.ImGui_PushFont(ctx, med_font, 16)
    local sw = reaper.ImGui_CalcTextSize(ctx, sub_display)
    reaper.ImGui_SetCursorScreenPos(ctx, cx + math.max(0, (avail_w - sw) * 0.5), cy + 58)
    reaper.ImGui_Text(ctx, sub_display)
    reaper.ImGui_PopFont(ctx)

    reaper.ImGui_PopStyleColor(ctx)

    -- Advance cursor past the box so the next widgets render below it.
    reaper.ImGui_SetCursorScreenPos(ctx, cx, cy + box_h + 4)
end

local function try_start_timer()
    local has_task = trim(state.task_label) ~= ""
    if has_task or state.skip_no_task_warn then
        start_timer()
    else
        state.pending_no_task_start = true
        reaper.ImGui_OpenPopup(ctx, "no_task_warning")
    end
end

local function draw_no_task_popup()
    local center_x, center_y = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetWindowViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, center_x, center_y, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    if reaper.ImGui_BeginPopupModal(ctx, "no_task_warning", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "No task is set. Start the timer anyway?")
        reaper.ImGui_Spacing(ctx)
        local chk, new_skip = reaper.ImGui_Checkbox(ctx, "Don't ask this again", state.skip_no_task_warn)
        if chk then
            state.skip_no_task_warn = new_skip
            save_settings()
        end
        reaper.ImGui_Spacing(ctx)
        if reaper.ImGui_Button(ctx, "Start", 80, 0) then
            start_timer()
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel", 80, 0) then
            state.pending_no_task_start = false
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
    end
end

local function draw_resume_prompt()
    local center_x, center_y = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetWindowViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, center_x, center_y, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize() + reaper.ImGui_WindowFlags_NoTitleBar()
    if reaper.ImGui_BeginPopupModal(ctx, "resume_prompt", nil, flags) then
        local msg = state.auto_paused
            and "Timer was auto-paused due to idle. Resume?"
            or "Timer is paused. Resume?"
        reaper.ImGui_PushFont(ctx, med_font, 16)
        local tw = reaper.ImGui_CalcTextSize(ctx, msg)
        local avail = reaper.ImGui_GetContentRegionAvail(ctx)
        if avail > tw then
            reaper.ImGui_SetCursorPosX(ctx, (avail - tw) * 0.5 + reaper.ImGui_GetCursorPosX(ctx))
        end
        reaper.ImGui_Text(ctx, msg)
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_Spacing(ctx)
        local btn_total = 80 + 8 + 100
        local btn_avail = reaper.ImGui_GetContentRegionAvail(ctx)
        if btn_avail > btn_total then
            reaper.ImGui_SetCursorPosX(ctx, (btn_avail - btn_total) * 0.5 + reaper.ImGui_GetCursorPosX(ctx))
        end
        if reaper.ImGui_Button(ctx, "Resume", 80, 0) then
            start_timer()
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Stay paused", 100, 0) then
            state.auto_paused = false
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
    end
end

local function draw_controls()
    local btn_label
    if state.running then
        btn_label = "Pause"
    elseif state.session_banked > 0 then
        btn_label = "Resume"
    else
        btn_label = "Start"
    end

    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local style_gap = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing())
    -- Scale buttons to fit: use fixed sizes when roomy, shrink when narrow
    local btn_w = math.min(80, math.floor((avail - style_gap * 2 - 110) * 0.5))
    local log_w = math.min(110, avail - btn_w * 2 - style_gap * 2)
    local row_w = btn_w + style_gap + btn_w + style_gap + log_w
    center_cursor(avail, row_w)

    if reaper.ImGui_Button(ctx, btn_label, btn_w, 30) then
        if state.running then
            pause_timer()
        else
            try_start_timer()
        end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reset", btn_w, 30) then reset_session() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Log session", log_w, 30) then log_session() end

    -- Prompt to resume: fires exactly once per pause cycle
    if not state.running and state.session_banked > 0
       and not state.paused_prompted and not state.resume_popup_done then
        state.resume_popup_done = true
        reaper.ImGui_OpenPopup(ctx, "resume_prompt")
    end

    draw_no_task_popup()
    draw_resume_prompt()
end

local function draw_centered_text(txt)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local tw = reaper.ImGui_CalcTextSize(ctx, txt)
    if avail > tw then
        reaper.ImGui_SetCursorPosX(ctx, (avail - tw) * 0.5)
    end
    reaper.ImGui_Text(ctx, txt)
end

local function draw_task_totals()
    local name = trim(state.task_label)
    if name == "" then return end
    local t = find_task(trim(state.project_label), trim(state.category_label), name)
    local prior = t and t.total or 0
    local this = session_elapsed()
    reaper.ImGui_Separator(ctx)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local full = string.format(
        "Previously: %s   This session: %s   Total: %s",
        format_hms(prior), format_hms(this), format_hms(prior + this))
    local full_w = reaper.ImGui_CalcTextSize(ctx, full)
    if avail >= full_w then
        center_cursor(avail, full_w)
        reaper.ImGui_Text(ctx, full)
    else
        draw_centered_text("Previously: " .. format_hms(prior))
        draw_centered_text("This session: " .. format_hms(this))
        draw_centered_text("Total: " .. format_hms(prior + this))
    end
end

------------------------------------------------------------------------
-- History: grouped by Project -> Category -> Task
------------------------------------------------------------------------
local edit_state = { active_id = nil, p = "", c = "", n = "" }

local function task_identity(t)
    return t.project .. "\0" .. t.category .. "\0" .. t.name
end

local function draw_task_edit_row(t, uid)
    if reaper.ImGui_Button(ctx, "Edit##ed_" .. uid) then
        edit_state.active_id = task_identity(t)
        edit_state.p = t.project
        edit_state.c = t.category
        edit_state.n = t.name
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Delete##del_" .. uid) then
        delete_task(t)
        return true
    end
    if edit_state.active_id == task_identity(t) then
        reaper.ImGui_SetNextItemWidth(ctx, 180)
        local _, np = reaper.ImGui_InputText(ctx, "Project##ep_" .. uid, edit_state.p)
        edit_state.p = np
        reaper.ImGui_SetNextItemWidth(ctx, 180)
        local _, nc = reaper.ImGui_InputText(ctx, "Category##ec_" .. uid, edit_state.c)
        edit_state.c = nc
        reaper.ImGui_SetNextItemWidth(ctx, 180)
        local _, nn = reaper.ImGui_InputText(ctx, "Name##en_" .. uid, edit_state.n)
        edit_state.n = nn
        if reaper.ImGui_Button(ctx, "Save##esv_" .. uid) then
            merge_or_rename(t, trim(edit_state.p), trim(edit_state.c), trim(edit_state.n))
            edit_state.active_id = nil
            return true
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel##ecn_" .. uid) then
            edit_state.active_id = nil
        end
        reaper.ImGui_Text(ctx, "(matching existing = merge)")
    end
    return false
end

local function group_tasks(only_this_sitting)
    -- returns: groups[project][category] = array of {task, sessions, total}
    local groups = {}
    for _, t in ipairs(tasks) do
        local filtered = {}
        local total = 0
        for _, s in ipairs(t.sessions) do
            if (not only_this_sitting) or ((s.ts or 0) >= SCRIPT_START_TS) then
                filtered[#filtered + 1] = s
                total = total + (s.actual or 0)
            end
        end
        if #filtered > 0 then
            local p = t.project ~= "" and t.project or "(no project)"
            local c = t.category ~= "" and t.category or "(no category)"
            groups[p] = groups[p] or {}
            groups[p][c] = groups[p][c] or {}
            local bucket = groups[p][c]
            bucket[#bucket + 1] = { task = t, sessions = filtered, total = total }
        end
    end
    return groups
end

local function draw_grouped_history(only_this_sitting, id_prefix)
    local groups = group_tasks(only_this_sitting)
    local project_names = {}
    for p in pairs(groups) do project_names[#project_names + 1] = p end
    table.sort(project_names)
    if #project_names == 0 then
        reaper.ImGui_Text(ctx, only_this_sitting
            and "(nothing logged since script launch)"
            or "(no tasks logged yet)")
        return
    end
    for _, pname in ipairs(project_names) do
        local proj_total = 0
        for _, cat in pairs(groups[pname]) do
            for _, entry in ipairs(cat) do proj_total = proj_total + entry.total end
        end
        local pid = id_prefix .. "_" .. pname
        if reaper.ImGui_TreeNode(ctx, string.format("%s  -  %s##%s", pname, format_hms(proj_total), pid)) then
            local cat_names = {}
            for c in pairs(groups[pname]) do cat_names[#cat_names + 1] = c end
            table.sort(cat_names)
            for _, cname in ipairs(cat_names) do
                local cat_total = 0
                for _, entry in ipairs(groups[pname][cname]) do cat_total = cat_total + entry.total end
                local cid = pid .. "_" .. cname
                if reaper.ImGui_TreeNode(ctx, string.format("%s  -  %s##%s", cname, format_hms(cat_total), cid)) then
                    for _, entry in ipairs(groups[pname][cname]) do
                        local tname = entry.task.name
                        local tid = cid .. "_" .. tname
                        local header = string.format("%s  -  %s (%d sessions)##%s",
                            tname, format_hms(entry.total), #entry.sessions, tid)
                        if reaper.ImGui_TreeNode(ctx, header) then
                            for i = #entry.sessions, 1, -1 do
                                local s = entry.sessions[i]
                                reaper.ImGui_Text(ctx, string.format(
                                    "  %s   planned %s  /  actual %s",
                                    s.date, format_hms(s.planned), format_hms(s.actual)))
                            end
                            if draw_task_edit_row(entry.task, tid) then
                                reaper.ImGui_TreePop(ctx)
                                reaper.ImGui_TreePop(ctx)
                                reaper.ImGui_TreePop(ctx)
                                return
                            end
                            reaper.ImGui_TreePop(ctx)
                        end
                    end
                    reaper.ImGui_TreePop(ctx)
                end
            end
            reaper.ImGui_TreePop(ctx)
        end
    end
end

local function draw_history()
    if reaper.ImGui_CollapsingHeader(ctx, "This sitting") then
        draw_grouped_history(true, "sit")
    end
    if reaper.ImGui_CollapsingHeader(ctx, "All time") then
        draw_grouped_history(false, "all")
    end
end

------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------
local function loop()
    check_idle()
    reaper.ImGui_SetNextWindowSize(ctx, 420, 520, reaper.ImGui_Cond_FirstUseEver())
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 420, 380, 16384, 16384)
    local visible, open = reaper.ImGui_Begin(ctx, 'Focus Timer', true)
    if visible then
        draw_settings()
        draw_task_input()
        reaper.ImGui_Spacing(ctx)
        draw_planned_inputs()
        reaper.ImGui_Spacing(ctx)
        draw_big_timer()
        reaper.ImGui_Spacing(ctx)
        draw_controls()
        draw_task_totals()
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        draw_history()
        reaper.ImGui_End(ctx)
    end
    if open then
        reaper.defer(loop)
    else
        if state.running then pause_timer() end
    end
end

reaper.defer(loop)
