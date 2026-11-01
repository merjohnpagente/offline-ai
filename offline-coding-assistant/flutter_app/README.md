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
