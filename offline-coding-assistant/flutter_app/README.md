# Offline AI — Flutter app

This folder contains the on-device Android app. See the [root README](../README.md) for the full description, download link, and build instructions.

Quick start:

```bash
bash ../tools/fetch_model.sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

The model is **not** committed to Git. The helper downloads the official Apache-2.0 Qwen2.5-Coder-1.5B-Instruct Q4_K_M GGUF (~1.1 GB) into `assets/models/model.gguf` and verifies its SHA-256. GitHub Actions does the same before building.

Chats, drafts, and settings are stored locally in SQLite. The release app has no `INTERNET` permission.

## Attaching a file

Tap the paperclip in the composer to attach a text or code file. The first
6 KB are copied into the model's system prompt for as long as the attachment
stays active; larger files are truncated. The attachment lives only in memory
for the current chat and is never uploaded or written to the database.
