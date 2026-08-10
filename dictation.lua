-- Free push-to-talk dictation (Hebrew), powered by Groq whisper-large-v3 (cloud, very fast)
-- Hold fn+Shift (no other key) to record, release to transcribe and paste at the cursor.
--
-- PRIVACY: the mic is only ever opened while you are actively pressing toward this hotkey -
-- never continuously in the background. See the "priming" note below for the one nuance.
--
-- Opening the mic costs ~0.5s (measured) with bin/dictation-recorder. It used to cost 1.4-3.5s
-- with ffmpeg, which swallowed most of every sentence. To claw back the rest without recording in the
-- background: we open the mic the moment you press fn alone (people naturally press the two
-- keys a beat apart), and only treat it as a real dictation once Shift completes the fn+Shift
-- combo. If the combo never completes (you pressed fn alone for something unrelated), the
-- primed recording is killed and its file deleted immediately - it is never transcribed,
-- sent anywhere, or kept.
--
-- Note: we deliberately do NOT prime on Shift alone. Shift is pressed constantly during normal
-- typing (every capital letter), and priming on it would open the mic all day long.

require("hs.ipc") -- enables the `hs -c '...'` CLI bridge from Terminal, for debugging

local GROQ_URL     = "https://api.groq.com/openai/v1/audio/transcriptions"
local GROQ_KEYFILE = os.getenv("HOME") .. "/.config/dictation-groq-key"
local GROQ_MODEL   = "whisper-large-v3" -- best Hebrew accuracy Groq offers; turbo is faster but weaker
local LANGUAGE     = "he"

-- Whisper's `prompt` biases its vocabulary toward these words. Measured on Hebrew test audio:
-- without it, tech jargon came out mangled (באג→בואג, צ׳קאאוט→צ'יקאות, "הדיפלוי לפרודקשן"→
-- "הדיפלויל פרודקשן"); with it, 3/3 sentences transcribed exactly. Costs zero extra latency.
--
-- This is deliberately used INSTEAD of an LLM cleanup pass. Tested llama-3.3-70b as a cleanup
-- layer and it silently rewrote "צ׳קאאוט" into "בדיקות" - a meaning change, worse than the
-- original error. Biasing the transcriber can only pick better words; it cannot invent content.
--
-- Add your own recurring vocabulary here (product names, client names, colleagues' names).
local VOCAB_PROMPT = "שיחה על פיתוח תוכנה. מונחים נפוצים: הבאג, באגים, דיפלוי, פרודקשן, " ..
    "סטייג׳ינג, קומפוננטה, צ׳קאאוט, ריפו, פוש, מרג׳, ברנץ׳, קומיט, סרבר, דאטהבייס, " ..
    "אנדפוינט, פיצ׳ר, ריפקטור, טסטים, איי־פי־איי, פרונטאנד, בקאנד."
local REC_FILE       = "/tmp/hs-dictation.wav"
local RECORDER       = os.getenv("HOME") .. "/.hammerspoon/bin/dictation-recorder"
local MIN_HOLD_SECS  = 0.35 -- ignore accidental taps shorter than this
local micReady       = false -- set when the recorder reports audio is actually flowing

-- Diagnostics. While on, every dictation keeps its audio and logs the text that came back, so a
-- bad transcription can be examined against what was actually recorded instead of guessed at.
-- Set to false to stop keeping audio on disk.
local KEEP_RECORDINGS = false
local ARCHIVE_DIR     = os.getenv("HOME") .. "/.hammerspoon/recordings"
local ARCHIVE_KEEP    = 20 -- prune to this many most-recent files
_G.lastRecording      = nil

local function readApiKey()
    local f = io.open(GROQ_KEYFILE, "r")
    if not f then return nil end
    local key = f:read("*a")
    f:close()
    key = key:gsub("^%s+", ""):gsub("%s+$", "")
    return key ~= "" and key or nil
end

_G.dictationLog = {}
local function log(msg)
    print("[dictation] " .. msg)
    table.insert(_G.dictationLog, os.date("%H:%M:%S") .. " " .. msg)
    if #_G.dictationLog > 200 then table.remove(_G.dictationLog, 1) end
end

local primed = false       -- mic opened on a single modifier key, combo not yet completed
local isRecording = false  -- both Ctrl+Shift confirmed down - a real dictation is in progress
local micTask = nil        -- the (single) recorder process behind either state above
local recordStartedAt = nil
local discardOnExit = false -- set when cancelled: delete the file once the process actually dies

local function openMic()
    discardOnExit = false
    micReady = false
    os.remove(REC_FILE)
    local task = hs.task.new(
        RECORDER,
        function(exitCode, stdOut, stdErr)
            log("recorder exited code=" .. tostring(exitCode))
            if stdErr and stdErr ~= "" then log("recorder stderr: " .. stdErr) end
            -- The recorder can still be finishing its device open after terminate(), so we only
            -- delete once it has ACTUALLY exited - deleting synchronously at cancel time raced
            -- against a file that did not exist yet, then reappeared moments later.
            if discardOnExit then
                os.remove(REC_FILE)
                log("discarded recording after process actually exited (cancelled)")
            end
        end,
        -- The recorder prints READY the instant audio actually starts landing on disk (~0.5s
        -- after launch). We only flip the on-screen cue then, so "🎙️ מקליט" never claims to be
        -- live while the device is still opening.
        --
        -- This MUST be passed here as hs.task.new's third argument. Calling
        -- task:setStreamingCallback() after construction silently never fires (verified).
        function(_, stdOut, _)
            if stdOut and stdOut:match("READY") then
                micReady = true
                log("mic READY - audio is now flowing")
                if isRecording then
                    hs.alert.closeAll()
                    hs.alert.show("🎙️ מקליט...", 999)
                end
            end
            return true
        end,
        { REC_FILE }
    )
    if not task then
        log("ERROR: hs.task.new returned nil for recorder")
        return nil
    end
    task:start()
    return task
end

-- Keep a copy of the audio we are about to send, so a bad result can be replayed and compared
-- against other providers/settings later.
--
-- Runs entirely off the hot path: hs.execute() is SYNCHRONOUS and each call spawns a shell, so
-- doing the copy+prune inline added a visible stall before every single upload. hs.task is async,
-- and this is fired only after the upload is already in flight.
local function archiveRecordingAsync()
    if not KEEP_RECORDINGS then return end
    hs.fs.mkdir(ARCHIVE_DIR)
    local dest = ARCHIVE_DIR .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".wav"
    _G.lastRecording = dest
    hs.task.new("/bin/sh", nil, { "-c", string.format(
        "cp %q %q 2>/dev/null; ls -1t %q/*.wav 2>/dev/null | tail -n +%d | xargs -I{} rm -f {}",
        REC_FILE, dest, ARCHIVE_DIR, ARCHIVE_KEEP + 1) }):start()
end

-- Duration of a 16 kHz mono 16-bit PCM WAV, straight from its byte count (44-byte header).
-- Deliberately not ffprobe: shelling out cost more than the number is worth.
local function wavSeconds(bytes)
    return math.max(0, (bytes - 44) / 32000)
end

local function killMicHard(task)
    if not task then return end
    local pid = task:pid()
    task:terminate()
    if pid and pid > 0 then
        hs.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
end

local function sendToGroq()
    local attrs = hs.fs.attributes(REC_FILE)
    if not attrs or attrs.size < 1000 then
        log("recording missing or too small: " .. tostring(attrs and attrs.size))
        hs.alert.closeAll()
        hs.alert.show("⚠️ ההקלטה לא נקלטה (בדוק הרשאת מיקרופון)")
        return
    end

    log(string.format("sending %.2fs of audio (%d bytes)", wavSeconds(attrs.size), attrs.size))

    local apiKey = readApiKey()
    if not apiKey then
        log("ERROR: no Groq API key at " .. GROQ_KEYFILE)
        hs.alert.closeAll()
        hs.alert.show("⚠️ לא נמצא מפתח Groq")
        return
    end

    local curlTask = hs.task.new(
        "/usr/bin/curl",
        function(exitCode, stdOut, stdErr)
            hs.alert.closeAll()
            log("curl exited code=" .. tostring(exitCode))
            if stdErr and stdErr ~= "" then log("curl stderr:\n" .. stdErr) end

            if exitCode ~= 0 then
                hs.alert.show("❌ Groq לא הגיב (בדוק חיבור אינטרנט)")
                return
            end

            if (stdOut or ""):match('"invalid_api_key"') or (stdOut or ""):match('"authentication_error"')
                or (stdOut or ""):match('Invalid API Key') then
                log("Groq auth error: " .. tostring(stdOut))
                hs.alert.show("❌ מפתח Groq לא תקין")
                return
            end

            local text = (stdOut or ""):match('"text"%s*:%s*"(.-)"')
            if not text then
                log("could not parse response: " .. tostring(stdOut))
                hs.alert.show("⚠️ תשובה לא צפויה מ-Groq")
                return
            end
            text = text:gsub("\\n", " "):gsub('\\"', '"'):gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" then
                hs.alert.show("⚠️ לא זוהה טקסט")
                return
            end

            log(string.format("TEXT (%.2fs from release to paste): %s",
                hs.timer.secondsSinceEpoch() - (_G.releasedAt or 0), text))

            local previousClipboard = hs.pasteboard.getContents()
            hs.pasteboard.setContents(text)
            hs.eventtap.keyStroke({"cmd"}, "v", 0)

            hs.timer.doAfter(1.0, function()
                if previousClipboard then
                    hs.pasteboard.setContents(previousClipboard)
                end
            end)
        end,
        { "-s", "-X", "POST", GROQ_URL,
          "-H", "Authorization: Bearer " .. apiKey,
          "-F", "file=@" .. REC_FILE,
          "-F", "model=" .. GROQ_MODEL,
          "-F", "language=" .. LANGUAGE,
          "-F", "prompt=" .. VOCAB_PROMPT,
          "-F", "response_format=json" }
    )
    curlTask:start()
    archiveRecordingAsync() -- after the upload is in flight, never before it
end

local function startPriming()
    if primed or isRecording then return end
    primed = true
    log("priming: opening mic on first modifier key")
    micTask = openMic()
end

local function cancelPriming()
    if not primed then return end
    primed = false
    log("priming cancelled (combo never completed) - discarding, never transcribed")
    discardOnExit = true
    if micTask then
        killMicHard(micTask)
        micTask = nil
    end
    os.remove(REC_FILE) -- in case a file already exists at this point; the exit callback covers the rest
end

local function startRecording()
    if isRecording then return end
    isRecording = true
    primed = false
    recordStartedAt = hs.timer.secondsSinceEpoch()
    log("start() - combo completed, isRecording=true")

    hs.alert.closeAll()
    -- Two distinct cues, because the difference matters: "מתחבר" means the mic is still opening
    -- and anything you say now is lost; "מקליט" (shown by the READY callback) means it is live.
    if micReady then
        hs.alert.show("🎙️ מקליט...", 999)
    else
        hs.alert.show("⏳ מתחבר...", 999)
    end

    if not micTask then
        -- both keys landed together with no priming window - open fresh now (costs ~0.5s)
        log("no priming task active, opening mic fresh")
        micTask = openMic()
    end
end

local function stopRecordingAndTranscribe()
    if not isRecording then return end
    isRecording = false

    local heldFor = hs.timer.secondsSinceEpoch() - (recordStartedAt or 0)
    _G.releasedAt = hs.timer.secondsSinceEpoch() -- for the release→paste timing in the log
    log("stop() heldFor=" .. string.format("%.2f", heldFor))

    if heldFor < MIN_HOLD_SECS then
        log("held only " .. string.format("%.2f", heldFor) .. "s, ignoring")
        discardOnExit = true
        if micTask then
            killMicHard(micTask)
            micTask = nil
        end
        hs.alert.closeAll()
        os.remove(REC_FILE)
        return
    end

    if micTask then
        micTask:terminate() -- gentle: lets the recorder write a valid WAV header before upload
        micTask = nil
    end

    hs.alert.closeAll()
    hs.alert.show("✍️ מתמלל...", 999)

    -- Wait for the recorder to finish writing the WAV header, but only as long as it actually
    -- takes. This used to be a flat 0.4s sleep on every dictation; the file is normally complete
    -- in well under 100ms, so that was mostly dead time the user felt on every single use.
    local deadline = hs.timer.secondsSinceEpoch() + 1.0
    local lastSize = -1
    local poll
    poll = function()
        local attrs = hs.fs.attributes(REC_FILE)
        local size = attrs and attrs.size or 0
        -- Ready once the file has stopped growing at a plausible size, or we run out of patience.
        if (size > 1000 and size == lastSize) or hs.timer.secondsSinceEpoch() > deadline then
            sendToGroq()
            return
        end
        lastSize = size
        hs.timer.doAfter(0.03, poll)
    end
    hs.timer.doAfter(0.03, poll)
end

local function isExactFnShift(flags)
    return flags.fn and flags.shift and not flags.cmd and not flags.alt and not flags.ctrl
end

-- Only fn alone primes the mic. Shift alone is NOT a priming trigger: it is pressed constantly
-- during ordinary typing, and priming on it would open the mic dozens of times a minute.
local function isPrimingModifierOnly(flags)
    if flags.cmd or flags.alt or flags.ctrl or flags.shift then return false end
    return flags.fn == true
end

local flagsWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
    local flags = e:getFlags()

    if isExactFnShift(flags) then
        startRecording()
    elseif isPrimingModifierOnly(flags) then
        if isRecording then
            stopRecordingAndTranscribe() -- one of the two keys was released
        else
            startPriming()
        end
    else
        if isRecording then
            stopRecordingAndTranscribe()
        elseif primed then
            cancelPriming()
        end
    end
    return false
end)
flagsWatcher:start()
_G.dictationTap = flagsWatcher -- exposed for `hs -c` debugging
_G.startRecording = startRecording -- exposed for `hs -c` debugging
_G.stopRecordingAndTranscribe = stopRecordingAndTranscribe -- exposed for `hs -c` debugging
_G.startPriming = startPriming -- exposed for `hs -c` debugging
_G.cancelPriming = cancelPriming -- exposed for `hs -c` debugging
_G.isPrimedOrRecording = function() return primed, isRecording end -- exposed for `hs -c` debugging

-- Ctrl+Cmd+R reloads this config after you edit it
hs.hotkey.bind({"ctrl", "cmd"}, "r", function()
    hs.reload()
end)

log("config loaded, accessibilityEnabled=" .. tostring(hs.accessibilityState()) ..
    " tapRunning=" .. tostring(flagsWatcher:isEnabled()))
hs.alert.show("✅ Dictation (Groq) loaded — hold fn+Shift to talk")
