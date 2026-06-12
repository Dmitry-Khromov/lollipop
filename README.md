# Lollipop 🍭

Free, system-wide hold-to-dictate for macOS. Hold **Fn+Shift** in any app, speak in English, German, Russian, Spanish (or most other languages — auto-detected), release — and the corrected text types itself into whatever field you were in.

> **Why "Lollipop"?** Its first words ever were "Ну что же, давай попробуем разгрызть этот леденец" ("well then, let's try to crack this lollipop"). What was actually said: "let's see if this thing works." The culprit turned out to be a microphone input volume of 25/100 — which is why the installer now checks yours.

## What it costs

Nothing to install, no subscription. You bring your own [Groq](https://console.groq.com) API key — the **free tier is more than enough** for personal dictation, and even paid usage is ~$0.11 per *hour* of speech.

## Install

```bash
git clone https://github.com/Dmitry-Khromov/lollipop.git
cd lollipop
./setup.sh
```

The script installs what's missing (Hammerspoon, ffmpeg via Homebrew), asks for your Groq key (free, no card: [console.groq.com/keys](https://console.groq.com/keys)), checks your mic input volume, and wires everything up. Re-run it anytime as a health check.

macOS will ask for two permissions:
1. **Accessibility** (System Settings → Privacy & Security) — needed to detect the hotkey and type the text
2. **Microphone** — popup on your first dictation

## Use

| Action | Effect |
|--------|--------|
| Hold **Fn+Shift**, speak, release | corrected text typed into the focused field |
| **Esc** while holding | cancel, nothing inserted |

You'll hear a "Pop" when recording starts (begin speaking just after it) and a "Tink" when text lands. On-the-fly cleanup fixes punctuation, obvious mis-recognitions, and self-corrections ("send it Monday — no wait, Tuesday" → "send it Tuesday") but never rephrases or translates.

## Privacy

Your audio is sent to Groq's API for transcription (and the transcript for cleanup) under **your own** API key. Nothing else leaves your machine; nothing is stored server-side by this tool. Don't dictate things your employer wouldn't want sent to a third-party API.

## Troubleshooting

- Every dictation logs the raw and cleaned transcript to `~/.hammerspoon/dictation.log`, and the last audio is kept at `~/.hammerspoon/dictation-recording.flac`.
- Output is fluent nonsense? Check your mic input volume (System Settings → Sound → Input) — quiet audio makes Whisper hallucinate. `./setup.sh` checks this.
- Nothing happens on Fn+Shift? Accessibility permission is missing, or another app (Wispr Flow, raycast, etc.) grabs the same combo.
- Tunables (models, max duration, sounds, cleanup on/off) are in the `CONFIG` block of `~/.hammerspoon/mac-dictation.lua`.

## Uninstall

```bash
rm ~/.hammerspoon/mac-dictation.lua ~/.hammerspoon/dictation.log ~/.hammerspoon/dictation-recording.flac
rm -rf ~/.config/mac-dictation
# then remove the Lollipop dofile line from ~/.hammerspoon/init.lua
```

## License

MIT
