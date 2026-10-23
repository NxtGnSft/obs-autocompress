# OBS → Whisperwise: automatic processing of meeting recordings

**English** | [Русский](README.ru.md)

When an OBS recording stops, `obs-autocompress.lua` queues the file (`queue/`) and starts a background worker,
which then asks whether to send the recording to Whisperwise (ww.nextgensoft.co). The original stays where it is.

Note: the prompts and messages in the scripts are in Russian; button names below are translated.

| | Windows | macOS |
|---|---|---|
| Worker | `compress.ps1` + `ask-upload.ps1` | `worker.sh` |
| What it does | re-encodes video with HandBrakeCLI (QuickSync) → `Videos\compressed` | extracts audio with `extract-audio` → `.m4a` next to the recording |
| Token | `whisperwise.config.json` | Keychain |
| Log | `compress.log`, `upload.log` | `worker.log` |

Sections up to "macOS" are about Windows.

## Setup (once)
1. OBS → Tools → Scripts → "+" → pick `obs-autocompress.lua` from this folder.
2. Done. Stop a recording → a few seconds later compression starts in the background; a Windows notification appears when it's finished.

## What you get
- H.265 via Intel QuickSync (runs on the GPU media engine, CPU stays almost idle), 15 fps, AAC mono audio at 64 kbps.
- One hour of meeting: ~2.7 GB before, roughly 30–100 MB after (depends on how much moves on screen).
- While OBS is recording, compression runs at lower priority and slower. Faster when not recording.
- Several recordings in a row are queued and compressed one at a time.

## Settings
At the top of `compress.ps1`:
- `$Quality` — 24 by default. Small text on screen → use 22; want a smaller file → 28.
- `$DeleteOriginal = $true` — delete the source after successful compression.
- `$OutDir` — where to put the result.

## Compress old recordings manually
```powershell
powershell -ExecutionPolicy Bypass -File compress.ps1 "$HOME\Videos\recording1.mp4" "$HOME\Videos\recording2.mp4"
```

## Troubleshooting
- `compress.log` — history: what was compressed, sizes, how long it took.
- `handbrake-last.log` — detailed HandBrake log for the last file.
- `failed\` — recordings that failed to compress (path inside the txt). To retry: move the txt back to `queue\` and run `compress.ps1` with no arguments.
- A black window flashes for a split second when compression starts: that's normal, it's how OBS launches the background process.
- HandBrakeCLI is installed via winget (`HandBrake.HandBrake.CLI`). Update: `winget upgrade HandBrake.HandBrake.CLI`.

## Uploading to Whisperwise (ww.nextgensoft.co)
After compression an always-on-top window pops up: project, title, "Send" / "No, keep it". No close button; it reminds you every minute.
- The token lives in `whisperwise.config.json` (create it at ww.nextgensoft.co/account.html; don't commit it). You can revoke it there too.
- Upload goes to `POST /upload` with a Bearer token; the project list comes from `GET /api/projects`.
- `upload.log` — what was sent / declined / errors. `pending\` — unanswered prompts, asked again after the next compression.
- Open the window manually: `powershell -ExecutionPolicy Bypass -File ask-upload.ps1`.
- Gotcha: a process started with `-WindowStyle Hidden` also hides its first window; the script forces it visible (`Show-Front`).

## First-time setup on a new machine
1. `winget install HandBrake.HandBrake.CLI` (needs Intel QuickSync; otherwise change the codec in `compress.ps1`).
2. Copy `whisperwise.config.example.json` to `whisperwise.config.json` and put your token in (ww.nextgensoft.co/account.html). The file is gitignored.
3. The `queue`, `failed`, `pending` folders are created on first run.
4. Add `obs-autocompress.lua` in OBS (Tools → Scripts).

## macOS
Video isn't re-encoded: Whisperwise only needs audio, and full video doesn't fit the server limit (500 MB).
`worker.sh` extracts audio with `extract-audio` (copies the AAC track without re-encoding, takes seconds) into a `.m4a` next to
the recording and asks about uploading. One hour of meeting ≈ 85 MB.

First-time setup:
1. `brew install ffmpeg` (PATH doesn't matter: OBS launched from Finder sees a bare PATH, the script adds `/opt/homebrew/bin` itself).
2. OBS → Settings → Output → Recording: MKV format (survives crashes, no "file still being written" retry needed),
   AAC audio codec (otherwise `extract-audio` can't copy the track into `.m4a`).
3. Token (created at ww.nextgensoft.co/account.html, revoked there too) goes into Keychain, not a file:
   `security add-generic-password -U -s whisperwise -a "$USER" -w 'TOKEN'`.
4. OBS → Tools → Scripts → "+" → `obs-autocompress.lua`.

What it looks like:
1. "Send to Whisperwise?" window with a title (defaults to the file name) → "Send" / "No, keep it".
2. After "Send" — project list (skipped if there's only one project). "Cancel" goes back to the first window.
3. Upload, then a notification with a link. Errors (network, token, server) show in the first window; you can retry.

Details:
- Esc doesn't close the window; with no answer it beeps and pops up again every minute. Unanswered items stay in `queue/` and are asked again on next run (survives reboots).
- Only one worker runs at a time (`.lock/`; a stale lock from a dead process is cleared automatically); others wait and drain the queue.
- `worker.log` — what was extracted / sent (with link) / errors and server response. `failed/` — extraction failed; retry: `mv failed/*.txt queue/ && ./worker.sh`.
- Manually: `./worker.sh ~/Movies/recording.mkv` (or a `.m4a` directly; with no arguments it drains the queue).
  `./extract-audio` also works standalone: with no arguments it takes the latest recording from `~/Movies`.
- Gotcha: macOS `/bin/bash` is 3.2 — on lines with Cyrillic write `${var}`, not `$var»`: bash treats Cyrillic bytes as part of the variable name (`unbound variable`).
- Gotcha: don't edit `worker.sh` while it's waiting with a window open — bash reads the script as it executes.

## License
[MIT](LICENSE)
