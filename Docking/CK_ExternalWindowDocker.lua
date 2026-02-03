-- @description External Window Docker
-- @author Cookie (Chris Kokkinos)
-- @version 1.7.0
-- @changelog
--   - Added keyboard shortcut support via companion toggle script
--   - Added re-embed last URL on startup option
--   - Performance: async window refresh (non-blocking)
--   - Performance: deferred settings persistence
--   - Performance: cached browser path detection
--   - Fixed dock transition crash handling
--   - Updated Help tab and Settings documentation
-- @about
--   # External Window Docker
--
--   Embed external application windows (browsers, media players, etc.) directly
--   into REAPER's docker system.
--
--   ## Features
--   - Launch URLs in app mode (Edge/Chrome) and auto-embed
--   - Embed any detected window (Spotify, YouTube, Discord, etc.)
--   - Favorites and URL history with right-click management
--   - Customizable theme colors and header height
--   - Keyboard shortcut support (via companion script)
--   - Re-embed last URL on startup
--   - Find Window by Title for hard-to-detect windows
--
--   ## Requirements
--   - ReaImGui
--   - js_ReaScriptAPI
--
--   ## Usage
--   1. Run this script from the Actions list
--   2. Dock the "External Window Docker" window
--   3. Click "Open Menu" to access all features
--   4. Use "Open & Embed" to launch and dock browser content
--
--   ## Keyboard Shortcut
--   Install the companion script "CK_ExternalWindowDocker_ToggleMenu"
--   and assign it a keyboard shortcut via Actions > Show action list.
-- @link GitHub https://github.com/chriskodekkinos/Kokkinos-Scripts
-- @provides
--   [main] .
--   [main] CK_ExternalWindowDocker_ToggleMenu.lua

-- CK_ExternalWindowDocker v1.7
-- Embed browser windows into REAPER
-- Author: Cookie
-- Requires: ReaImGui, js_ReaScriptAPI

-- Check extensions
if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("ReaImGui required", "Error", 0)
    return
end
if not reaper.JS_Window_Find then
    reaper.ShowMessageBox("js_ReaScriptAPI required", "Error", 0)
    return
end

-- Constants
local GWL_STYLE, GWL_EXSTYLE = -16, -20
local WS_CHILD, WS_VISIBLE, WS_OVERLAPPEDWINDOW, WS_CLIPSIBLINGS = 0x40000000, 0x10000000, 0x00CF0000, 0x04000000

local SCRIPT_PATH = reaper.GetResourcePath() .. "/Scripts/"
local HISTORY_FILE = SCRIPT_PATH .. "CK_ExternalWindowDocker_history.txt"
local SETTINGS_FILE = SCRIPT_PATH .. "CK_ExternalWindowDocker_settings.txt"
local FAVORITES_FILE = SCRIPT_PATH .. "CK_ExternalWindowDocker_favorites.txt"

local MENU_WIDTH, MENU_MIN_HEIGHT, MENU_MAX_HEIGHT = 320, 300, 900
local TITLE_MAX_LENGTH, HISTORY_DISPLAY_LIMIT = 35, 5

-- Settings (defaults)
local settings = {
    max_history = 10,
    preferred_browser = "edge",
    auto_embed_timeout = 8,
    hide_spotify_warning = false,
    hide_tips_popup = false,
    header_height = 28,
    menu_x = nil,
    menu_y = nil,
    menu_height = 540,
    color_header = 0x4A90D9FF,
    color_header_hover = 0x5BA0E9FF,
    color_playing = 0xFFFFFFFF,
    color_status_error = 0xFF6B6BFF,
    color_status_ok = 0x81C784FF,
    auto_reembed = false,
    last_embed_url = nil,
    last_embed_title = nil,
}

-- State
local ctx = nil
local browser_available = { edge = false, chrome = false }
local embedded_hwnd, embedded_title, embedded_url, docker_hwnd, docker_hwnd_str = nil, "", nil, nil, ""
local is_embedded, embed_time = false, 0
local show_menu_window, menu_just_opened, current_tab, changing_window = false, false, 0, false
local status_message, status_is_error = "", false
local show_spotify_popup, pending_spotify_hwnd, pending_spotify_title = false, nil, nil
local show_tips_banner, tips_checked = false, false
local available_windows, windows_need_refresh, search_text = {}, true, ""
local refresh_index, refresh_found, refresh_in_progress = 0, {}, false
local refresh_terms = {"Chrome", "Edge", "Firefox", "Spotify", "YouTube", "Twitch", "Netflix", "Discord", "VLC", "Music", "Mini Player", "Web Player"}
local url_input, url_history, selected_history_idx, pinned_favorites = "https://www.youtube.com", {}, nil, {}
local pending_embed_url, pending_embed_time, last_update, last_embed_check = nil, 0, 0, 0
local main_window_open, prev_main_visible = true, true
local settings_dirty, settings_dirty_time = false, 0

-- Utility
local function truncate(str, max_len)
    if not str then return "" end
    return #str > max_len and str:sub(1, max_len - 3) .. "..." or str
end

-- Settings Persistence
local function load_settings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local key, val = line:match("^([^=]+)=(.+)$")
        if key and val then
            if key == "max_history" then settings.max_history = tonumber(val) or 10
            elseif key == "preferred_browser" then settings.preferred_browser = val
            elseif key == "header_height" then settings.header_height = tonumber(val) or 28
            elseif key == "auto_embed_timeout" then settings.auto_embed_timeout = tonumber(val) or 8
            elseif key == "hide_spotify_warning" then settings.hide_spotify_warning = (val == "true")
            elseif key == "hide_tips_popup" then settings.hide_tips_popup = (val == "true")
            elseif key == "menu_x" then settings.menu_x = tonumber(val)
            elseif key == "menu_y" then settings.menu_y = tonumber(val)
            elseif key == "menu_height" then settings.menu_height = tonumber(val) or 540
            elseif key == "color_header" then settings.color_header = tonumber(val) or 0x4A90D9FF
            elseif key == "color_playing" then settings.color_playing = tonumber(val) or 0xFFFFFFFF
            elseif key == "auto_reembed" then settings.auto_reembed = (val == "true")
            elseif key == "last_embed_url" then settings.last_embed_url = val
            elseif key == "last_embed_title" then settings.last_embed_title = (val ~= "" and val or nil)
            end
        end
    end
    f:close()
end

local function save_settings()
    local f = io.open(SETTINGS_FILE, "w")
    if not f then return end
    f:write("max_history=" .. settings.max_history .. "\n")
    f:write("preferred_browser=" .. settings.preferred_browser .. "\n")
    f:write("header_height=" .. settings.header_height .. "\n")
    f:write("auto_embed_timeout=" .. settings.auto_embed_timeout .. "\n")
    f:write("hide_spotify_warning=" .. tostring(settings.hide_spotify_warning) .. "\n")
    f:write("hide_tips_popup=" .. tostring(settings.hide_tips_popup) .. "\n")
    if settings.menu_x then f:write("menu_x=" .. math.floor(settings.menu_x) .. "\n") end
    if settings.menu_y then f:write("menu_y=" .. math.floor(settings.menu_y) .. "\n") end
    f:write("menu_height=" .. math.floor(settings.menu_height) .. "\n")
    f:write("color_header=" .. settings.color_header .. "\n")
    f:write("color_playing=" .. settings.color_playing .. "\n")
    f:write("auto_reembed=" .. tostring(settings.auto_reembed) .. "\n")
    if settings.last_embed_url then f:write("last_embed_url=" .. settings.last_embed_url .. "\n") end
    if settings.last_embed_title then f:write("last_embed_title=" .. settings.last_embed_title .. "\n") end
    f:close()
end

-- Mark settings as needing save (deferred to reduce file I/O)
local function mark_settings_dirty()
    settings_dirty = true
    settings_dirty_time = reaper.time_precise()
end

-- Flush dirty settings to disk if enough time has passed
local function flush_settings()
    if settings_dirty and (reaper.time_precise() - settings_dirty_time) > 0.5 then
        save_settings()
        settings_dirty = false
    end
end

-- History Persistence
local function load_history()
    local f = io.open(HISTORY_FILE, "r")
    if f then
        url_history = {}
        for line in f:lines() do
            if line ~= "" and #url_history < settings.max_history then
                local url, title = line:match("^([^|]+)|?(.*)$")
                if url then
                    table.insert(url_history, {url = url, title = (title and title ~= "") and title or nil})
                end
            end
        end
        f:close()
    else
        url_history = {{url = "https://www.youtube.com"}, {url = "https://www.twitch.tv"}}
    end
end

local function save_history()
    local f = io.open(HISTORY_FILE, "w")
    if not f then return end
    for i, entry in ipairs(url_history) do
        if i > settings.max_history then break end
        f:write(entry.url .. (entry.title and ("|" .. entry.title) or "") .. "\n")
    end
    f:close()
end

local function add_to_history(url, title)
    for i = #url_history, 1, -1 do
        if url_history[i].url == url then table.remove(url_history, i) end
    end
    table.insert(url_history, 1, {url = url, title = title})
    while #url_history > settings.max_history do table.remove(url_history) end
    save_history()
end

local function update_history_title(url, title)
    for _, entry in ipairs(url_history) do
        if entry.url == url then entry.title = title; save_history(); return end
    end
end

-- Favorites Persistence
local function load_favorites()
    local f = io.open(FAVORITES_FILE, "r")
    if not f then pinned_favorites = {}; return end
    pinned_favorites = {}
    for line in f:lines() do
        if line ~= "" then
            local url, title = line:match("^([^|]+)|?(.*)$")
            if url then table.insert(pinned_favorites, {url = url, title = (title and title ~= "") and title or nil}) end
        end
    end
    f:close()
end

local function save_favorites()
    local f = io.open(FAVORITES_FILE, "w")
    if not f then return end
    for _, entry in ipairs(pinned_favorites) do
        f:write(entry.url .. (entry.title and ("|" .. entry.title) or "") .. "\n")
    end
    f:close()
end

local function add_to_favorites(url, title)
    for _, entry in ipairs(pinned_favorites) do if entry.url == url then return false end end
    table.insert(pinned_favorites, {url = url, title = title})
    save_favorites()
    return true
end

local function remove_from_favorites(index)
    if index > 0 and index <= #pinned_favorites then
        table.remove(pinned_favorites, index)
        save_favorites()
        return true
    end
    return false
end

-- URL Helpers
local function title_looks_like_url(title)
    if not title or title == "" then return true end
    local lt = title:lower()
    return lt:find("youtube.com/") or lt:find("youtu.be/") or lt:find("twitch.tv/") or
           lt:find("netflix.com/") or lt:find("spotify.com/") or lt:find("discord.com/") or
           lt:match("^https?://") or lt:match("^www%.")
end

local function normalize_url(url)
    if not url or url == "" then return "" end
    url = url:match("^%s*(.-)%s*$")
    return url:match("^https?://") and url or ("https://" .. url)
end

local function get_url_display(entry)
    local url = type(entry) == "table" and entry.url or entry
    local title = type(entry) == "table" and entry.title or nil
    if title and title ~= "" then
        return truncate(title:gsub(" %- YouTube$", ""):gsub(" %- Twitch$", "")
            :gsub(" %- Google Chrome$", ""):gsub(" %- Microsoft Edge$", ""):gsub(" %- Watch$", ""), TITLE_MAX_LENGTH)
    end
    local display = url:gsub("https?://", ""):gsub("www%.", "")
    if display:find("youtube.com") then return "YouTube"
    elseif display:find("twitch.tv") then
        local channel = display:match("twitch.tv/([^/?]+)")
        return "Twitch" .. (channel and (": " .. channel) or "")
    elseif display:find("netflix.com") then return "Netflix"
    elseif display:find("spotify.com") then return "Spotify"
    end
    return truncate(display, 30)
end

-- Browser Detection (cached after first lookup)
local browser_path_cache = {}
local function get_browser_path(browser)
    if browser_path_cache[browser] ~= nil then
        return browser_path_cache[browser] or nil  -- false means "checked, not found"
    end
    local paths = {
        edge = {"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
                "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe"},
        chrome = {"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
                  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"}
    }
    for _, path in ipairs(paths[browser] or {}) do
        local f = io.open(path, "r")
        if f then f:close(); browser_path_cache[browser] = path; return path end
    end
    browser_path_cache[browser] = false
    return nil
end

local function detect_browsers()
    browser_available.edge = get_browser_path("edge") ~= nil
    browser_available.chrome = get_browser_path("chrome") ~= nil
    if not browser_available[settings.preferred_browser] then
        settings.preferred_browser = browser_available.edge and "edge" or (browser_available.chrome and "chrome" or settings.preferred_browser)
    end
end

-- Window Functions
local function get_rect(hwnd)
    if not hwnd then return nil end
    local ok, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
    return ok and {left=l, top=t, right=r, bottom=b, width=r-l, height=b-t} or nil
end

local function window_exists(hwnd)
    return hwnd and reaper.JS_Window_GetRect(hwnd)
end

local function find_docker()
    return reaper.JS_Window_Find("External Window Docker", true)
end

local function is_app_window(hwnd)
    if not hwnd then return false end
    local title = reaper.JS_Window_GetTitle(hwnd) or ""
    local class = reaper.JS_Window_GetClassName(hwnd) or ""
    if class ~= "Chrome_WidgetWin_1" and class ~= "Chrome_WidgetWin_0" then return false end
    local lt = title:lower()
    return not (lt:find("- google chrome") or lt:find("- microsoft edge") or lt:find("- mozilla firefox") or lt:find("- brave"))
end

local function is_spotify_miniplayer(title)
    return title and title:lower():find("web player")
end

local function is_window_allowed(title, class)
    if not title or title == "" then return false end
    local lt = title:lower()
    local excluded = {"reaper", "reascript", "external window docker", "devtools", "console", "docker menu",
        "legacy window", "gdi+", "widget", "cefbrowserwindow", "chrome_rendererwidgethostview",
        "intermediate d3d window", "overlay input trap"}
    for _, p in ipairs(excluded) do if lt:find(p, 1, true) then return false end end
    local allowed_class = {Chrome_WidgetWin_1=true, Chrome_WidgetWin_0=true, MozillaWindowClass=true,
        SpotifyMainWindow=true, Chrome_WidgetWin_2=true}
    if allowed_class[class] then return true end
    local allowed = {"chrome", "edge", "firefox", "spotify", "youtube", "twitch", "netflix", "discord",
        "vlc", "music", "video", "- watch", "mini player", "web player"}
    for _, p in ipairs(allowed) do if lt:find(p, 1, true) then return true end end
    return false
end

-- Start an async window refresh (non-blocking, spreads work across frames)
local function refresh_windows()
    refresh_index = 0
    refresh_found = {}
    refresh_in_progress = true
    available_windows = {}
    windows_need_refresh = false
end

-- Process a batch of search terms per frame (keeps UI responsive)
local function refresh_windows_step()
    if not refresh_in_progress then return end
    local batch = 4  -- terms per frame
    for _ = 1, batch do
        refresh_index = refresh_index + 1
        if refresh_index > #refresh_terms then
            -- Done - sort results
            table.sort(available_windows, function(a,b)
                return a.is_app ~= b.is_app and a.is_app or a.title:lower() < b.title:lower()
            end)
            refresh_in_progress = false
            return
        end
        local hwnd = reaper.JS_Window_Find(refresh_terms[refresh_index], false)
        if hwnd then
            local s = tostring(hwnd)
            if not refresh_found[s] then
                refresh_found[s] = true
                local title = reaper.JS_Window_GetTitle(hwnd) or ""
                local class = reaper.JS_Window_GetClassName(hwnd) or ""
                if is_window_allowed(title, class) then
                    local is_app = is_app_window(hwnd)
                    table.insert(available_windows, {hwnd=hwnd, title=title, is_app=is_app,
                        display=truncate(title, 40), icon=is_app and "[App] " or ""})
                end
            end
        end
    end
end

-- Embedding Functions
local function do_embed(child, parent)
    if not child or not parent then return false end
    local rect = get_rect(parent)
    if not rect then return false end
    reaper.JS_Window_SetLong(child, GWL_STYLE, WS_CHILD + WS_VISIBLE + WS_CLIPSIBLINGS)
    reaper.JS_Window_SetLong(child, GWL_EXSTYLE, 0)
    reaper.JS_Window_SetParent(child, parent)
    local h = rect.height - settings.header_height
    if h > 50 then reaper.JS_Window_SetPosition(child, 0, settings.header_height, rect.width, h) end
    reaper.JS_Window_Show(child, "SHOW")
    return true
end

local function check_embedded_window_exists()
    if not is_embedded or not embedded_hwnd then return true end
    local now = reaper.time_precise()
    if now - embed_time < 2.0 or now - last_embed_check < 0.5 then return true end
    last_embed_check = now
    if not window_exists(embedded_hwnd) then
        embedded_hwnd, embedded_title, embedded_url, docker_hwnd, docker_hwnd_str = nil, "", nil, nil, ""
        is_embedded = false
        status_message, status_is_error = "Window closed", false
        return false
    end
    return true
end

local function update_position()
    if not is_embedded or not embedded_hwnd or not check_embedded_window_exists() then return end
    local now = reaper.time_precise()
    if now - last_update < 0.033 then return end
    last_update = now
    if not window_exists(docker_hwnd) then
        local new_docker = find_docker()
        if new_docker and tostring(new_docker) ~= docker_hwnd_str then
            docker_hwnd, docker_hwnd_str = new_docker, tostring(new_docker)
            if window_exists(embedded_hwnd) then do_embed(embedded_hwnd, docker_hwnd) else is_embedded = false end
        end
        return
    end
    local rect = get_rect(docker_hwnd)
    if not rect then return end
    local h = rect.height - settings.header_height
    if h > 50 and rect.width > 50 then
        reaper.JS_Window_SetPosition(embedded_hwnd, 0, settings.header_height, rect.width, h)
    end
    if embedded_url and title_looks_like_url(embedded_title) then
        local current_title = reaper.JS_Window_GetTitle(embedded_hwnd)
        if current_title and not title_looks_like_url(current_title) then
            embedded_title = current_title
            update_history_title(embedded_url, current_title)
            embedded_url = nil
        end
    end
end

local function release_window()
    if not embedded_hwnd then return end
    if window_exists(embedded_hwnd) then
        reaper.JS_Window_SetLong(embedded_hwnd, GWL_STYLE, WS_OVERLAPPEDWINDOW + WS_VISIBLE)
        reaper.JS_Window_SetParent(embedded_hwnd, nil)
        reaper.JS_Window_SetPosition(embedded_hwnd, 100, 100, 900, 600)
        reaper.JS_Window_Show(embedded_hwnd, "SHOW")
    end
    embedded_hwnd, embedded_title, docker_hwnd, docker_hwnd_str, embedded_url = nil, "", nil, "", nil
    is_embedded, changing_window = false, false
end

local function embed_window(hwnd, title)
    if is_embedded and embedded_hwnd then release_window() end
    docker_hwnd = find_docker()
    if not docker_hwnd then return false end
    docker_hwnd_str = tostring(docker_hwnd)
    if do_embed(hwnd, docker_hwnd) then
        embedded_hwnd, embedded_title, is_embedded = hwnd, title, true
        embed_time = reaper.time_precise()
        status_message, show_menu_window, changing_window = "", false, false
        return true
    end
    return false
end

local function try_embed_window(hwnd, title)
    local lt = (title or ""):lower()
    if lt:find("spotify") and not is_spotify_miniplayer(title) and not settings.hide_spotify_warning then
        show_spotify_popup, pending_spotify_hwnd, pending_spotify_title = true, hwnd, title
        return false
    end
    return embed_window(hwnd, title)
end

-- App Mode Launch
local function launch_app_mode(url, auto_embed)
    url = normalize_url(url)
    if url == "" then return false end
    local path = get_browser_path(settings.preferred_browser)
    if not path then return false end
    os.execute(string.format('start "" "%s" --app="%s"', path, url))
    add_to_history(url)
    if auto_embed then
        if is_embedded then release_window() end
        pending_embed_url, pending_embed_time = url, reaper.time_precise()
        status_message, show_menu_window = "Launching...", false
    end
    return true
end

local function check_pending_embed()
    if not pending_embed_url then return end
    local elapsed = reaper.time_precise() - pending_embed_time
    if elapsed > settings.auto_embed_timeout then
        pending_embed_url, status_message, status_is_error = nil, "Timeout - window not found", true
        return
    end
    local domain = pending_embed_url:match("://([^/]+)")
    if not domain then return end
    domain = domain:gsub("www%.", "")
    local terms = {domain, domain:match("^([^%.]+)")}
    local path_part = pending_embed_url:match("://[^/]+/([^/?]+)")
    if path_part then table.insert(terms, path_part) end
    for _, term in ipairs(terms) do
        if term then
            local hwnd = reaper.JS_Window_Find(term, false)
            if hwnd and is_app_window(hwnd) then
                local win_title = reaper.JS_Window_GetTitle(hwnd) or pending_embed_url
                if embed_window(hwnd, win_title) then
                    embedded_url = pending_embed_url
                    settings.last_embed_url = pending_embed_url
                    settings.last_embed_title = win_title
                    save_settings()
                    update_history_title(pending_embed_url, win_title)
                    pending_embed_url, status_message = nil, ""
                    return
                end
            end
        end
    end
end

-- UI: Spotify Warning Popup
local function draw_spotify_popup()
    if not show_spotify_popup then return end
    reaper.ImGui_OpenPopup(ctx, "Spotify Recommendation")
    if reaper.ImGui_BeginPopupModal(ctx, "Spotify Recommendation", true, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "For the best experience, use Spotify's")
        reaper.ImGui_Text(ctx, "Mini Player instead of the main window.")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, 0x888888FF, "To open Mini Player:")
        reaper.ImGui_TextColored(ctx, 0x888888FF, "1. Open Spotify desktop app")
        reaper.ImGui_TextColored(ctx, 0x888888FF, "2. Click the Mini Player button")
        reaper.ImGui_TextColored(ctx, 0x888888FF, "   (bottom right, near volume)")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)
        local changed, val = reaper.ImGui_Checkbox(ctx, "Don't show this again", settings.hide_spotify_warning)
        if changed then settings.hide_spotify_warning = val; save_settings() end
        reaper.ImGui_Spacing(ctx)
        if reaper.ImGui_Button(ctx, "Embed Anyway", 120, 0) then
            if pending_spotify_hwnd and pending_spotify_title then embed_window(pending_spotify_hwnd, pending_spotify_title) end
            show_spotify_popup, pending_spotify_hwnd, pending_spotify_title = false, nil, nil
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel", 120, 0) then
            show_spotify_popup, pending_spotify_hwnd, pending_spotify_title = false, nil, nil
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
    end
end

-- UI: Tips Banner
local function draw_tips_banner()
    if not show_tips_banner then return end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x4A90D9FF)
    reaper.ImGui_Text(ctx, "Welcome!")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_BulletText(ctx, "Dock the Embeddable Window FIRST")
    reaper.ImGui_BulletText(ctx, "Then embed your content")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF6B6BFF)
    reaper.ImGui_TextWrapped(ctx, "Changing dock state with active content may crash the script.")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    local changed, val = reaper.ImGui_Checkbox(ctx, "Don't show again", settings.hide_tips_popup)
    if changed then settings.hide_tips_popup = val; save_settings() end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), settings.color_header)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), settings.color_header_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), settings.color_playing)
    if reaper.ImGui_Button(ctx, "Got it!", -1, 0) then
        show_tips_banner, show_menu_window, menu_just_opened, current_tab = false, true, true, 0
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
end

-- UI: Windows Tab
local function draw_windows_tab()
    if is_embedded and not changing_window then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), settings.color_playing)
        reaper.ImGui_Text(ctx, "Now Playing:")
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_TextWrapped(ctx, embedded_title)
        reaper.ImGui_Spacing(ctx)
        if reaper.ImGui_Button(ctx, "Change Window", -1, 0) then changing_window = true; refresh_windows() end
        if reaper.ImGui_Button(ctx, "Release Window", -1, 0) then release_window() end
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)
    end

    if not is_embedded or changing_window then
        if changing_window then
            reaper.ImGui_TextColored(ctx, 0xFFCC00FF, "Select new window:")
            if reaper.ImGui_Button(ctx, "Cancel", -1, 0) then changing_window = false end
            reaper.ImGui_Spacing(ctx)
        else
            reaper.ImGui_Text(ctx, "Available Windows:")
        end

        if reaper.ImGui_BeginChild(ctx, "winlist", -1, 140, reaper.ImGui_ChildFlags_Borders()) then
            if #available_windows > 0 then
                for i, win in ipairs(available_windows) do
                    if reaper.ImGui_Selectable(ctx, win.icon .. win.display .. "##w" .. i) then
                        try_embed_window(win.hwnd, win.title)
                    end
                end
            else
                reaper.ImGui_TextColored(ctx, 0x888888FF, "(No windows found)")
                reaper.ImGui_TextColored(ctx, 0x888888FF, "Click Refresh or open an app")
            end
            reaper.ImGui_EndChild(ctx)
        end

        if reaper.ImGui_Button(ctx, "Refresh Window List", -1, 0) then refresh_windows() end
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        reaper.ImGui_Text(ctx, "Find Window by Title:")
        reaper.ImGui_TextColored(ctx, 0x888888FF, "(Partial Match)")
        reaper.ImGui_SetNextItemWidth(ctx, -60)
        local enter
        enter, search_text = reaper.ImGui_InputText(ctx, "##srch", search_text, reaper.ImGui_InputTextFlags_EnterReturnsTrue())
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Find", 50, 0) or enter then
            if search_text ~= "" then
                local hwnd = reaper.JS_Window_Find(search_text, false)
                if hwnd then try_embed_window(hwnd, reaper.JS_Window_GetTitle(hwnd) or search_text)
                else status_message, status_is_error = "No window found", true end
            end
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        if #pinned_favorites > 0 then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFD700FF)
            reaper.ImGui_Text(ctx, "Favorites:")
            reaper.ImGui_PopStyleColor(ctx)
            for i, entry in ipairs(pinned_favorites) do
                reaper.ImGui_PushID(ctx, "fav" .. i)
                if reaper.ImGui_Button(ctx, get_url_display(entry), -1, 0) then launch_app_mode(entry.url, true) end
                if reaper.ImGui_BeginPopupContextItem(ctx) then
                    if reaper.ImGui_MenuItem(ctx, "Open & Embed") then launch_app_mode(entry.url, true) end
                    if reaper.ImGui_MenuItem(ctx, "Open Only") then launch_app_mode(entry.url, false) end
                    reaper.ImGui_Separator(ctx)
                    if reaper.ImGui_MenuItem(ctx, "Remove from Favorites") then remove_from_favorites(i) end
                    reaper.ImGui_EndPopup(ctx)
                end
                reaper.ImGui_PopID(ctx)
            end
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)
        end

        reaper.ImGui_Text(ctx, "Launch URL in App Mode:")
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        _, url_input = reaper.ImGui_InputText(ctx, "##url", url_input)
        if reaper.ImGui_Button(ctx, "Open & Embed (" .. (settings.preferred_browser == "edge" and "Edge" or "Chrome") .. ")", -1, 0) then
            launch_app_mode(url_input, true)
        end

        if #url_history > 0 then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Text(ctx, "Recent URLs:")
            for i, entry in ipairs(url_history) do
                if i > HISTORY_DISPLAY_LIMIT then break end
                reaper.ImGui_PushID(ctx, i)
                if reaper.ImGui_Selectable(ctx, get_url_display(entry) .. "##h", selected_history_idx == i) then
                    selected_history_idx = i
                end
                if reaper.ImGui_BeginPopupContextItem(ctx) then
                    if reaper.ImGui_MenuItem(ctx, "Open & Embed") then launch_app_mode(entry.url, true); selected_history_idx = nil end
                    if reaper.ImGui_MenuItem(ctx, "Open Only (No Embed)") then launch_app_mode(entry.url, false); selected_history_idx = nil end
                    reaper.ImGui_Separator(ctx)
                    if reaper.ImGui_MenuItem(ctx, "Add to Favorites") then add_to_favorites(entry.url, entry.title) end
                    reaper.ImGui_Separator(ctx)
                    if reaper.ImGui_MenuItem(ctx, "Remove from History") then table.remove(url_history, i); save_history(); selected_history_idx = nil end
                    reaper.ImGui_EndPopup(ctx)
                end
                reaper.ImGui_PopID(ctx)
            end
            if selected_history_idx and url_history[selected_history_idx] then
                reaper.ImGui_Spacing(ctx)
                if reaper.ImGui_Button(ctx, "Open & Embed Selected", -1, 0) then
                    launch_app_mode(url_history[selected_history_idx].url, true)
                    selected_history_idx = nil
                end
            end
            if #url_history > HISTORY_DISPLAY_LIMIT then
                reaper.ImGui_TextColored(ctx, 0x888888FF, "(" .. (#url_history - HISTORY_DISPLAY_LIMIT) .. " more in history)")
            end
            reaper.ImGui_Spacing(ctx)
            if reaper.ImGui_Button(ctx, "Clear History", -1, 0) then url_history = {}; save_history(); selected_history_idx = nil end
        end
    end
end

-- UI: Settings Tab
local function draw_settings_tab()
    reaper.ImGui_Text(ctx, "Preferred Browser:")
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_RadioButton(ctx, "Microsoft Edge", settings.preferred_browser == "edge") then
        if browser_available.edge then settings.preferred_browser = "edge"; save_settings() end
    end
    if not browser_available.edge then reaper.ImGui_SameLine(ctx); reaper.ImGui_TextColored(ctx, 0x888888FF, "(Not Found)") end
    if reaper.ImGui_RadioButton(ctx, "Google Chrome", settings.preferred_browser == "chrome") then
        if browser_available.chrome then settings.preferred_browser = "chrome"; save_settings() end
    end
    if not browser_available.chrome then reaper.ImGui_SameLine(ctx); reaper.ImGui_TextColored(ctx, 0x888888FF, "(Not Found)") end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Header Height: " .. settings.header_height .. "px")
    reaper.ImGui_TextColored(ctx, 0x888888FF, "(Space Above Embedded Window)")
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local changed, val = reaper.ImGui_SliderInt(ctx, "##hdr", settings.header_height, 20, 50)
    if changed then settings.header_height = val; save_settings() end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Auto-Embed Timeout: " .. settings.auto_embed_timeout .. "s")
    reaper.ImGui_TextColored(ctx, 0x888888FF, "(How Long to Wait for Browser")
    reaper.ImGui_TextColored(ctx, 0x888888FF, " Window After Launching URL)")
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    changed, val = reaper.ImGui_SliderInt(ctx, "##timeout", settings.auto_embed_timeout, 3, 15)
    if changed then settings.auto_embed_timeout = val; save_settings() end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "History Limit: " .. settings.max_history)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    changed, val = reaper.ImGui_SliderInt(ctx, "##hist", settings.max_history, 5, 25)
    if changed then
        settings.max_history = val
        while #url_history > settings.max_history do table.remove(url_history) end
        save_settings(); save_history()
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Theme Colors:")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Primary Color:")
    reaper.ImGui_TextColored(ctx, 0x888888FF, "(Buttons, Tabs, Sliders)")
    local color_changed, new_color = reaper.ImGui_ColorEdit3(ctx, "##col_header", (settings.color_header >> 8) & 0xFFFFFF, reaper.ImGui_ColorEditFlags_NoInputs())
    if color_changed then
        settings.color_header = (new_color << 8) + 0xFF
        settings.color_header_hover = settings.color_header + 0x10101000
        save_settings()
    end

    reaper.ImGui_Text(ctx, "Font Color:")
    reaper.ImGui_TextColored(ctx, 0x888888FF, "(Header Text)")
    local font_changed, font_color = reaper.ImGui_ColorEdit3(ctx, "##col_playing", (settings.color_playing >> 8) & 0xFFFFFF, reaper.ImGui_ColorEditFlags_NoInputs())
    if font_changed then settings.color_playing = (font_color << 8) | 0xFF; save_settings() end
    reaper.ImGui_SameLine(ctx); reaper.ImGui_TextColored(ctx, settings.color_playing, "Preview")

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    local spotify_changed, spotify_val = reaper.ImGui_Checkbox(ctx, "Hide Spotify Mini Player Warning", settings.hide_spotify_warning)
    if spotify_changed then settings.hide_spotify_warning = spotify_val; save_settings() end
    local tips_changed, tips_val = reaper.ImGui_Checkbox(ctx, "Hide Quick Tips on Startup", settings.hide_tips_popup)
    if tips_changed then settings.hide_tips_popup = tips_val; save_settings() end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    local reembed_changed, reembed_val = reaper.ImGui_Checkbox(ctx, "Re-embed Last URL on Startup", settings.auto_reembed)
    if reembed_changed then settings.auto_reembed = reembed_val; save_settings() end
    if settings.last_embed_url then
        reaper.ImGui_TextColored(ctx, 0x888888FF, "Last: " .. truncate(settings.last_embed_url:gsub("https?://", ""), 35))
    else
        reaper.ImGui_TextColored(ctx, 0x888888FF, "(No URL saved yet)")
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFD700FF)
    reaper.ImGui_Text(ctx, "Keyboard Shortcut:")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_TextColored(ctx, 0x888888FF, "Add CK_ExternalWindowDocker_ToggleMenu")
    reaper.ImGui_TextColored(ctx, 0x888888FF, "to REAPER's Actions list, then assign")
    reaper.ImGui_TextColored(ctx, 0x888888FF, "a shortcut via Actions > Show action list.")

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Reset All Settings", -1, 0) then
        settings.menu_x, settings.menu_y, settings.menu_height = nil, nil, 540
        settings.header_height, settings.color_header, settings.color_playing = 28, 0x4A90D9FF, 0xFFFFFFFF
        settings.hide_spotify_warning, settings.hide_tips_popup = false, false
        settings.auto_reembed, settings.last_embed_url, settings.last_embed_title = false, nil, nil
        save_settings()
    end
end

-- UI: Help Tab
local function draw_help_tab()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x4A90D9FF)
    reaper.ImGui_Text(ctx, "CK_ExternalWindowDocker v1.7")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_TextColored(ctx, 0x888888FF, "Embed browser windows into REAPER")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFD700FF)
    reaper.ImGui_Text(ctx, "Getting Started:")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_BulletText(ctx, "Dock the Embeddable Window first")
    reaper.ImGui_BulletText(ctx, "Use 'Open & Embed' to launch URLs directly")
    reaper.ImGui_BulletText(ctx, "Or select from Available Windows list")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFD700FF)
    reaper.ImGui_Text(ctx, "Favorites:")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_BulletText(ctx, "Right-click any URL in history")
    reaper.ImGui_BulletText(ctx, "Select 'Add to Favorites'")
    reaper.ImGui_BulletText(ctx, "Favorites appear as quick-launch buttons")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x1DB954FF)
    reaper.ImGui_Text(ctx, "Spotify Tips:")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_BulletText(ctx, "Use Mini Player for best results")
    reaper.ImGui_BulletText(ctx, "Open Spotify desktop app")
    reaper.ImGui_BulletText(ctx, "Click Mini Player button (bottom right)")
    reaper.ImGui_BulletText(ctx, "Then embed the 'Web Player' window")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFD700FF)
    reaper.ImGui_Text(ctx, "Tips:")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_BulletText(ctx, "Use 'Find Window by Title' for Discord Streams")
    reaper.ImGui_BulletText(ctx, "Search partial channel/server names")
    reaper.ImGui_BulletText(ctx, "Refresh list if windows don't appear")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF6B6BFF)
    reaper.ImGui_Text(ctx, "Important:")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_BulletText(ctx, "Release content before docking/undocking")
    reaper.ImGui_BulletText(ctx, "Dock changes with active content may crash")
end

-- UI: Menu Window
local function draw_menu_window()
    if not show_menu_window or not ctx or not reaper.ImGui_ValidatePtr(ctx, 'ImGui_Context*') then return end

    if menu_just_opened then
        local use_saved = settings.menu_x and settings.menu_y and
            settings.menu_x >= 0 and settings.menu_y >= 0 and settings.menu_x < 4000 and settings.menu_y < 3000
        if not use_saved then settings.menu_x, settings.menu_y = nil, nil; save_settings() end
        reaper.ImGui_SetNextWindowPos(ctx, use_saved and settings.menu_x or 100, use_saved and settings.menu_y or 100)
        reaper.ImGui_SetNextWindowSize(ctx, MENU_WIDTH, settings.menu_height)
        menu_just_opened = false
        refresh_windows()
    end

    reaper.ImGui_SetNextWindowSizeConstraints(ctx, MENU_WIDTH, MENU_MIN_HEIGHT, MENU_WIDTH, MENU_MAX_HEIGHT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), settings.color_header)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), settings.color_header_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabSelected(), settings.color_header)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(), settings.color_header_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(), settings.color_header)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), settings.color_header_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), settings.color_header)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), settings.color_header - 0x20202000)

    local begin_ok, visible, open = pcall(reaper.ImGui_Begin, ctx, "External Window Docker Menu", true, reaper.ImGui_WindowFlags_NoCollapse())
    if not begin_ok or visible == nil or type(visible) ~= "boolean" then
        pcall(reaper.ImGui_PopStyleColor, ctx, 8)
        return
    end

    if visible then
        local wx, wy = reaper.ImGui_GetWindowPos(ctx)
        local ww, wh = reaper.ImGui_GetWindowSize(ctx)
        if wx ~= settings.menu_x or wy ~= settings.menu_y or wh ~= settings.menu_height then
            settings.menu_x, settings.menu_y, settings.menu_height = wx, wy, wh
            mark_settings_dirty()
        end
        if reaper.ImGui_BeginTabBar(ctx, "menutabs") then
            if reaper.ImGui_BeginTabItem(ctx, "Windows") then current_tab = 0; reaper.ImGui_Spacing(ctx); draw_windows_tab(); reaper.ImGui_EndTabItem(ctx) end
            if reaper.ImGui_BeginTabItem(ctx, "Settings") then current_tab = 1; reaper.ImGui_Spacing(ctx); draw_settings_tab(); reaper.ImGui_EndTabItem(ctx) end
            if reaper.ImGui_BeginTabItem(ctx, "Help") then current_tab = 2; reaper.ImGui_Spacing(ctx); draw_help_tab(); reaper.ImGui_EndTabItem(ctx) end
            reaper.ImGui_EndTabBar(ctx)
        end
        draw_spotify_popup()
    end

    if reaper.ImGui_ValidatePtr(ctx, 'ImGui_Context*') then pcall(reaper.ImGui_End, ctx) end
    pcall(reaper.ImGui_PopStyleColor, ctx, 8)
    if open == false then show_menu_window, changing_window = false, false end
end

-- Main Loop
local function do_frame()
    if not tips_checked then
        tips_checked = true
        if not settings.hide_tips_popup then show_tips_banner = true end
    end
    -- Poll for external toggle signal (companion script shortcut)
    local toggle = reaper.GetExtState("CK_ExternalWindowDocker", "toggle_menu")
    if toggle == "1" then
        reaper.DeleteExtState("CK_ExternalWindowDocker", "toggle_menu", false)
        show_menu_window = not show_menu_window
        if show_menu_window then menu_just_opened, current_tab = true, 0 end
    end

    check_pending_embed()
    refresh_windows_step()

    local begin_ok, visible, open = pcall(reaper.ImGui_Begin, ctx, "External Window Docker", true,
        reaper.ImGui_WindowFlags_NoCollapse() + reaper.ImGui_WindowFlags_NoScrollbar())
    if not begin_ok or visible == nil or type(visible) ~= "boolean" then return true end

    local is_dock_transition = (prev_main_visible == true and visible == false)
    prev_main_visible = visible

    if visible then
        draw_tips_banner()
        if not show_tips_banner then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), settings.color_header)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), settings.color_header_hover)
            local label = is_embedded and embedded_title ~= "" and
                ("Now Playing: " .. truncate(embedded_title:gsub(" %- YouTube$", ""):gsub(" %- Twitch$", "")
                    :gsub(" %- Google Chrome$", ""):gsub(" %- Microsoft Edge$", ""):gsub(" %- Watch$", ""), TITLE_MAX_LENGTH - 13))
                or "Open Menu"
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), settings.color_playing)
            if reaper.ImGui_Button(ctx, label, -1, 22) then
                show_menu_window = not show_menu_window
                if show_menu_window then menu_just_opened, current_tab = true, 0 end
            end
            reaper.ImGui_PopStyleColor(ctx, 3)
        end
        if pending_embed_url then reaper.ImGui_TextColored(ctx, 0xFFFF88FF, "Launching...")
        elseif status_message ~= "" then
            reaper.ImGui_TextColored(ctx, status_is_error and settings.color_status_error or settings.color_status_ok, status_message)
        end
    end

    if not is_dock_transition then pcall(reaper.ImGui_End, ctx) end
    draw_menu_window()
    update_position()
    flush_settings()
    return open == nil and true or open
end

local function main_loop()
    if not ctx then return end
    if not reaper.ImGui_ValidatePtr(ctx, 'ImGui_Context*') then
        ctx = reaper.ImGui_CreateContext("External Window Docker")
        if not ctx then if is_embedded then release_window() end; return end
        prev_main_visible = true
    end
    local success, result = pcall(do_frame)
    if not success then prev_main_visible = true; reaper.defer(main_loop); return end
    main_window_open = result
    if result then reaper.defer(main_loop)
    else
        if settings_dirty then save_settings() end
        if is_embedded then release_window() end
        reaper.DeleteExtState("CK_ExternalWindowDocker", "toggle_menu", false)
        ctx = nil
    end
end

-- Initialization
ctx = reaper.ImGui_CreateContext("External Window Docker")
if ctx then
    load_settings()
    load_history()
    load_favorites()
    detect_browsers()
    reaper.DeleteExtState("CK_ExternalWindowDocker", "toggle_menu", false)
    if settings.auto_reembed and settings.last_embed_url then
        launch_app_mode(settings.last_embed_url, true)
    end
    windows_need_refresh = true
    main_loop()
end
