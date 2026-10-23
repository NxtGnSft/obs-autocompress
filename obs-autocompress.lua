-- OBS: after a recording stops, queue the file and start compress.ps1 (HandBrakeCLI).
-- Install: OBS -> Tools -> Scripts -> "+" -> pick this file.
obs = obslua

local dir = script_path()  -- folder of this script, with trailing slash
local counter = 0

local function enqueue(path)
    counter = counter + 1
    local qfile = string.format("%squeue/%s-%03d.txt", dir, os.date("%Y%m%d-%H%M%S"), counter)
    local f = io.open(qfile, "wb")
    if not f then
        obs.script_log(obs.LOG_WARNING, "cannot write queue file " .. qfile)
        return
    end
    f:write(path)  -- UTF-8; the worker reads it as UTF-8, so Cyrillic names are safe
    f:close()

    local ps1 = (dir .. "compress.ps1"):gsub("/", "\\")
    os.execute('start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. ps1 .. '"')
    obs.script_log(obs.LOG_INFO, "queued for compression: " .. path)
end

local function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        local path = obs.obs_frontend_get_last_recording()
        if path and path ~= "" then enqueue(path) end
    end
end

function script_description()
    return "После остановки записи сжимает файл через HandBrakeCLI.\n" ..
           "Результат: Видео\\compressed. Лог: compress.log рядом со скриптом."
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
end
