-- OBS: after a recording stops, queue the file and start the worker:
-- Windows: compress.ps1 (HandBrakeCLI), macOS: worker.sh (extract-audio).
-- Install: OBS -> Tools -> Scripts -> "+" -> pick this file.
obs = obslua

local dir = script_path()  -- folder of this script, with trailing slash
local windows = package.config:sub(1, 1) == "\\"
local counter = 0

local function enqueue(path)
    counter = counter + 1
    local qfile = string.format("%squeue/%s-%03d.txt", dir, os.date("%Y%m%d-%H%M%S"), counter)
    local f = io.open(qfile, "wb")
    if not f then  -- first run: queue/ does not exist yet
        if windows then
            os.execute('mkdir "' .. (dir .. "queue"):gsub("/", "\\") .. '"')
        else
            os.execute('mkdir -p "' .. dir .. 'queue"')
        end
        f = io.open(qfile, "wb")
    end
    if not f then
        obs.script_log(obs.LOG_WARNING, "cannot write queue file " .. qfile)
        return
    end
    f:write(path)  -- UTF-8; the worker reads it as UTF-8, so Cyrillic names are safe
    f:close()

    if windows then
        local ps1 = (dir .. "compress.ps1"):gsub("/", "\\")
        os.execute('start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. ps1 .. '"')
    else
        -- "&" matters: os.execute blocks the OBS UI until the command returns.
        os.execute('nohup /bin/bash "' .. dir .. 'worker.sh" >/dev/null 2>&1 &')
    end
    obs.script_log(obs.LOG_INFO, "queued: " .. path)
end

local function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        local path = obs.obs_frontend_get_last_recording()
        if path and path ~= "" then enqueue(path) end
    end
end

function script_description()
    return "After a recording stops: Windows compresses it with HandBrakeCLI (Videos\\compressed, compress.log);\n" ..
           "macOS extracts audio to .m4a next to the recording (worker.log). Then asks whether to send it to Whisperwise."
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
end
