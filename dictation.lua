-- Lollipop 🍭 — system-wide hold-to-dictate for macOS (Fn+Shift) via Groq Whisper.
-- Installed by setup.sh as ~/.hammerspoon/mac-dictation.lua. https://github.com/dphromov

local function findFFmpeg()
  for _, p in ipairs({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }) do
    if hs.fs.attributes(p) then return p end
  end
  return nil
end

local CONFIG = {
  keyFile = os.getenv("HOME") .. "/.config/mac-dictation/groq_key",
  ffmpegPath = findFFmpeg(),
  audioFile = os.getenv("HOME") .. "/.hammerspoon/dictation-recording.flac",
  micDevice = ":default", -- follows the system input device (AirPods, built-in, …)
  minPressSec = 0.4,
  maxRecordSec = 180,
  transcribeModel = "whisper-large-v3",
  cleanupModel = "llama-3.3-70b-versatile",
  cleanupEnabled = true,
  sounds = true,
}

local CLEANUP_PROMPT = [[You are a dictation post-processor. The user dictated text in some language (English, German, Russian, Spanish, or another). Fix ONLY:
- obvious speech-to-text mis-recognitions (wrong homophones, garbled words where the intended word is clear from context)
- punctuation and capitalization
- filler artifacts ("um", "эээ") if clearly unintentional
- self-corrections: when the speaker corrects themselves mid-stream ("send it Monday... no wait, Tuesday", "the Microsoft... sorry, I mean the microphone setting"), keep ONLY the final corrected version — drop the abandoned attempt AND the correction phrase itself ("sorry, I mean", "no wait", "вернее", "то есть", "ой, нет"). The output must read as if the speaker said it right the first time.

Beyond these rules, do NOT rephrase, shorten, expand, or translate. Keep the original language and wording. If a phrase seems garbled, odd, or nonsensical but you are not CERTAIN what the speaker meant, leave it exactly as transcribed — never substitute words with different meanings, never guess. A faithful weird transcript is better than an invented fluent one. Output ONLY the corrected text, with no quotes around it and no commentary.]]

-- ---------------------------------------------------------------- state

local apiKey = nil
local recording = false
local processing = false
local recordStart = 0
local ffmpegTask = nil
local cancelled = false
local maxTimer = nil
local alertId = nil
local escTap = nil
local stopRecording

local function log(msg) print("[dictation] " .. msg) end

-- append raw/cleaned pairs to a debug log so transcription vs cleanup issues are separable
local LOG_FILE = os.getenv("HOME") .. "/.hammerspoon/dictation.log"
local function appendLog(stage, text)
  local f = io.open(LOG_FILE, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. stage .. "] " .. text .. "\n")
    f:close()
  end
end

local function loadApiKey()
  local env = os.getenv("GROQ_API_KEY")
  if env and env ~= "" then return env end
  local f = io.open(CONFIG.keyFile, "r")
  if not f then return nil end
  local key = f:read("*a"):gsub("%s+", "")
  f:close()
  if key == "" then return nil end
  return key
end

local function showAlert(text, seconds)
  if alertId then hs.alert.closeSpecific(alertId) end
  alertId = hs.alert.show(text, { textSize = 20, radius = 8 }, hs.screen.mainScreen(), seconds or 3600)
end

local function closeAlert()
  if alertId then hs.alert.closeSpecific(alertId); alertId = nil end
end

local function playSound(name)
  if not CONFIG.sounds then return end
  local s = hs.sound.getByName(name)
  if s then s:play() end
end

-- ---------------------------------------------------------------- groq

local function insertText(text)
  processing = false
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    showAlert("🎤 (empty)", 1)
    return
  end
  closeAlert()
  playSound("Tink")
  hs.eventtap.keyStrokes(text)
end

local function cleanupAndInsert(rawText)
  if not CONFIG.cleanupEnabled then
    insertText(rawText)
    return
  end
  local body = hs.json.encode({
    model = CONFIG.cleanupModel,
    temperature = 0,
    messages = {
      { role = "system", content = CLEANUP_PROMPT },
      { role = "user", content = rawText },
    },
  })
  hs.http.asyncPost(
    "https://api.groq.com/openai/v1/chat/completions",
    body,
    { ["Authorization"] = "Bearer " .. apiKey, ["Content-Type"] = "application/json" },
    function(status, responseBody)
      -- any cleanup failure falls back to the raw transcript — never drop a dictation
      local text = rawText
      if status == 200 then
        local ok, parsed = pcall(hs.json.decode, responseBody)
        if ok and parsed and parsed.choices and parsed.choices[1]
           and parsed.choices[1].message and parsed.choices[1].message.content then
          text = parsed.choices[1].message.content
          appendLog("cleaned", text)
        else
          log("cleanup parse failed, inserting raw transcript")
        end
      else
        log("cleanup HTTP " .. tostring(status) .. ", inserting raw transcript")
      end
      insertText(text)
    end
  )
end

local function transcribe()
  local attrs = hs.fs.attributes(CONFIG.audioFile)
  if not attrs or attrs.size < 5000 then
    processing = false
    closeAlert()
    log("audio file missing or too small (" .. tostring(attrs and attrs.size) .. " bytes)")
    showAlert("🎤 no audio captured", 1.5)
    return
  end
  local curl = hs.task.new("/usr/bin/curl", function(exitCode, stdOut, stdErr)
    if exitCode ~= 0 then
      processing = false
      closeAlert()
      log("transcription curl failed: " .. tostring(stdErr))
      showAlert("🎤 transcription failed", 2)
      return
    end
    local ok, parsed = pcall(hs.json.decode, stdOut)
    if not ok or not parsed or not parsed.text then
      processing = false
      closeAlert()
      log("transcription response unparseable: " .. tostring(stdOut):sub(1, 200))
      showAlert("🎤 transcription failed", 2)
      return
    end
    appendLog("raw", parsed.text)
    cleanupAndInsert(parsed.text)
  end, {
    "-s", "--max-time", "60",
    "-X", "POST", "https://api.groq.com/openai/v1/audio/transcriptions",
    "-H", "Authorization: Bearer " .. apiKey,
    "-F", "file=@" .. CONFIG.audioFile,
    "-F", "model=" .. CONFIG.transcribeModel,
  })
  curl:start()
end

-- ---------------------------------------------------------------- recording

local function stopEscTap()
  if escTap then escTap:stop(); escTap = nil end
end

local function startRecording()
  if recording or processing then return end
  if not CONFIG.ffmpegPath then
    showAlert("🎤 ffmpeg not found — run setup.sh", 2)
    return
  end
  if not apiKey then
    apiKey = loadApiKey()
    if not apiKey then
      showAlert("🎤 Groq key missing — run setup.sh", 2)
      return
    end
  end
  recording = true
  cancelled = false
  recordStart = hs.timer.secondsSinceEpoch()
  os.remove(CONFIG.audioFile)
  ffmpegTask = hs.task.new(CONFIG.ffmpegPath, function()
    -- fires after terminate(): decide whether to transcribe or discard
    ffmpegTask = nil
    if cancelled then
      os.remove(CONFIG.audioFile)
      return
    end
    transcribe()
  end, {
    "-hide_banner", "-y",
    "-f", "avfoundation", "-i", CONFIG.micDevice,
    -- speechnorm: built-in mic capture is often quiet, which makes Whisper mishear
    "-af", "speechnorm=e=12.5:r=0.0001:l=1",
    "-ar", "16000", "-ac", "1",
    CONFIG.audioFile,
  })
  ffmpegTask:start()
  playSound("Pop")
  showAlert("🎤 listening…")
  maxTimer = hs.timer.doAfter(CONFIG.maxRecordSec, function()
    if recording then stopRecording(false) end
  end)
  -- Esc while holding = cancel without inserting
  escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if e:getKeyCode() == hs.keycodes.map.escape and recording then
      stopRecording(true)
      return true
    end
    return false
  end)
  escTap:start()
end

stopRecording = function(cancel)
  if not recording then return end
  recording = false
  stopEscTap()
  if maxTimer then maxTimer:stop(); maxTimer = nil end
  local held = hs.timer.secondsSinceEpoch() - recordStart
  cancelled = cancel or (held < CONFIG.minPressSec)
  if cancelled then
    closeAlert()
  else
    processing = true
    showAlert("✍️ transcribing…")
  end
  if ffmpegTask then
    ffmpegTask:terminate() -- SIGTERM: ffmpeg finalizes the file, then the task callback runs
  else
    processing = false
    closeAlert()
  end
end

-- ---------------------------------------------------------------- trigger

-- Hold Fn+Shift (and nothing else) to record; releasing either key stops.
local flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local f = e:getFlags()
  if not recording then
    if f.fn and f.shift and not (f.cmd or f.alt or f.ctrl) then
      startRecording()
    end
  else
    if not (f.fn and f.shift) then
      stopRecording(false)
    end
  end
  return false
end)
flagsTap:start()

-- keep a global reference so the eventtap is never garbage-collected
DictationFlagsTap = flagsTap

apiKey = loadApiKey()
if apiKey then
  log("loaded, hold Fn+Shift to dictate")
else
  log("WARNING: no Groq key — set GROQ_API_KEY or run setup.sh (expected " .. CONFIG.keyFile .. ")")
end

-- without Accessibility the eventtap silently never fires — make that failure loud.
-- the `true` argument asks macOS to show its grant prompt.
if hs.accessibilityState(true) then
  showAlert("🍭 Lollipop ready — hold Fn+Shift to dictate", 2)
else
  log("WARNING: Accessibility permission missing — hotkey cannot work until granted")
  showAlert("🍭 Lollipop needs Accessibility permission:\nSystem Settings → Privacy & Security → Accessibility → enable Hammerspoon,\nthen re-run setup.sh", 12)
end
