---
name: voicer
description: Read and change Voicer, the local macOS dictation and meeting-notes app — pull meeting notes and recordings, search dictation history, and change Voicer's settings. Use when the user mentions Voicer, their meeting notes or recordings, what was said in a meeting, their dictation history, or wants a Voicer setting changed.
---

# Voicer — reach into its local data

Voicer keeps everything as plain files on this Mac. There is no server and no MCP; read the files directly.
To install this file: copy the `voicer` folder into your agent's skills folder (Claude Code: `~/.claude/skills/`).

## Where things live

| What | Where | How to read |
|---|---|---|
| Meeting notes | `~/Documents/Voicer Meetings/<yyyy-MM-dd HHmm> <call app>.md` | Read the Markdown |
| Meeting audio (one mixed file) | same folder, same name, `.m4a` | Path only; don't upload it anywhere |
| Meeting raw data | `~/Library/Application Support/com.ashadmohammed.Voicer/Meetings/<id>/meeting.json` + per-track audio | Read only |
| Dictation history | `~/Library/Application Support/com.ashadmohammed.Voicer/default.store` (SQLite) | `sqlite3 -readonly` |
| Dictionary (vocabulary, auto-fix rules) | `~/Library/Application Support/com.ashadmohammed.Voicer/dictionary.store` | `sqlite3 -readonly` |
| Settings | macOS preferences, domain `com.ashadmohammed.Voicer` | `defaults read com.ashadmohammed.Voicer` |

Newest meeting: `ls -t ~/Documents/"Voicer Meetings"/*.md | head -1`.

## Dictation history

Table `ZTRANSCRIPTION`: `ZTEXT` (what was said), `ZENHANCEDTEXT` (after AI cleanup, if on), `ZTIMESTAMP` (seconds since
2001; add 978307200 for unix time), `ZDURATION` (audio seconds), `ZTRANSCRIPTIONDURATION` (processing seconds),
`ZTRANSCRIPTIONMODELNAME`.

```bash
sqlite3 -readonly -header -column ~/Library/Application\ Support/com.ashadmohammed.Voicer/default.store \
  "select datetime(ZTIMESTAMP+978307200,'unixepoch','localtime') at_time, substr(ZTEXT,1,80) text
   from ZTRANSCRIPTION order by ZTIMESTAMP desc limit 20;"
```

Dictionary tables: `ZVOCABULARYWORD` (words to recognise), `ZWORDREPLACEMENT` (auto-fix rules).

## Changing settings

1. Quit Voicer first: `osascript -e 'quit app id "com.ashadmohammed.Voicer"'`. A running app can overwrite an outside change.
2. Back up: `defaults export com.ashadmohammed.Voicer ~/voicer-prefs-backup-$(date +%Y%m%d-%H%M).plist`
3. Change with `defaults write com.ashadmohammed.Voicer <key> <value>`, then `open -a Voicer`.

Common keys: `primaryRecordingShortcutMode`, `ShowLiveTranscript`, `IsMenuBarOnly`, `ShowMenuBarIcon`, `RecorderType`,
`isSystemMuteEnabled`, `selectedAudioDeviceUID`. The speech model is Parakeet Ultra; don't change it.

## Rules
- Read-only by default. Change settings only when the user asks, and always back up first (step 2).
- Meeting notes and audio are private conversations. Never send them to an outside service without the user's ok.
