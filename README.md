# JAI

A fully on-device coding assistant. A Flutter chat app runs a quantized GGUF
model with llama.cpp on the phone — no server, no API key, and the Android
build has no `INTERNET` permission. A small FastAPI gateway is included for
desktop use and for pointing OpenAI-compatible clients (OpenCode, Continue,
etc.) at the same local model.

## Download

Get the latest **arm64** APK from the
[latest release](https://github.com/merjohnpagente/offline-ai/releases/latest).
The APK is debug-signed for sideloading (not Play Store distribution), bundles
the model, downloads at about 600 MB, and needs roughly 1.2 GB of free space.
Android 7.0+ on a 64-bit ARM device is required.

Pushing to `main` runs the `Build Android APK` workflow, which downloads and
verifies the model, runs the analyzer and tests, builds the arm64 APK, and
publishes it to the `latest` release.

## Architecture

```
Flutter app (Android/iOS/desktop)
  └─ llamadart (llama.cpp) ──► bundled model.gguf          # no network at all

Desktop / editor clients
  └─ FastAPI gateway :8080 ──► llama-server :8081 ──► GGUF
```

## Repository layout

| Path | What it is |
| --- | --- |
| `offline-coding-assistant/flutter_app/` | Flutter chat app. Streams replies, stores chats in private SQLite, manages conversations and generation settings. |
| `offline-coding-assistant/backend/` | FastAPI gateway with OpenAI-compatible `/v1/chat/completions` (SSE passthrough), `/chat`, `/health`, `/v1/models`. |
| `offline-coding-assistant/tools/` | One-time model download helpers (`fetch_model.ps1` / `fetch_model.sh`). |
| `training/` | Pinned requirements for fine-tuning the model with Unsloth on a Colab T4 or local NVIDIA GPU. |
| `eval/` | `eval_compare.py` plus held-out tasks, comparing a base model against a fine-tuned one. |
| `.github/workflows/` | CI that builds and publishes the arm64 APK to the `latest` release. |

## Flutter app

```bash
cd offline-coding-assistant/flutter_app
flutter pub get

# One-time: download the default Qwen2.5-Coder-0.5B-Instruct Q4_K_M (~470 MB)
powershell -ExecutionPolicy Bypass -File ../tools/fetch_model.ps1   # Windows
bash ../tools/fetch_model.sh                                        # macOS/Linux

flutter run
```

The GGUF is bundled as a Flutter asset. On first launch Android streams it into
app-private storage through a `MethodChannel`, so the file is never loaded into
Dart memory in one piece. Chats, drafts, and settings live in `offline_ai.db`
inside the app sandbox.

Use the paperclip button in the composer to attach a text or code file. The
first 6 KB are added to the prompt while the attachment stays active; larger
files are truncated. Files are read through the system picker, never uploaded,
and never written to the database.

To ship your own fine-tune, replace `assets/models/model.gguf` and rebuild:

```bash
flutter build apk --release
```

The model file is git-ignored — only `assets/models/README.md` is committed.

## Backend gateway

Requires a `llama-server` binary (from a llama.cpp release) on `PATH`, or set
`LLAMA_SERVER_BIN`.

```bash
cd offline-coding-assistant/backend
python -m pip install -r requirements.txt

# Point at a running llama-server...
set LLAMA_SERVER_URL=http://127.0.0.1:8081
# ...or let the gateway spawn one:
set MODEL_PATH=C:\models\qwen2.5-coder-7b-ft-Q4_K_M.gguf

python start.py          # launches FastAPI on :8080 and verifies /health
```

Useful environment variables: `MODEL_PATH`, `LLAMA_SERVER_BIN`,
`LLAMA_SERVER_URL`, `LLAMA_PORT`, `N_CTX`, `N_GPU_LAYERS`, `THREADS`,
`SYSTEM_PROMPT_FILE`.

Clients can then use `http://localhost:8080/v1` as an OpenAI-compatible base
URL with any non-empty API key.

## Fine-tuning

```bash
python -m pip install --upgrade pip==26.1.2
python -m pip install -r training/requirements-train.txt
```

The pins target Unsloth `2026.10.11` on Python 3.12. On Colab, do not install
`torch` from PyPI — use the CUDA build Colab already provides.

## Evaluation

```bash
python -m pip install requests
python eval/eval_compare.py \
  --tasks eval/heldout_tasks.jsonl \
  --base-url http://127.0.0.1:11434/v1 --base-model qwen2.5-coder:7b \
  --ft-url  http://127.0.0.1:8080/v1 --ft-model  qwen2.5-coder-ft \
  --out eval_results
```

Each task is scored on syntax validity, exact/fuzzy match against a reference
solution, and optional pass@1 from hidden tests. The report includes a paired
win/loss summary, a bootstrap confidence interval, and a sign test.

> Hidden tests execute model-generated code. Run the evaluator in a disposable
> VM or container if you do not trust the model or the task file.

## Privacy

- The mobile app has no network permission and no telemetry.
- The gateway binds locally by default; nothing leaves the machine unless you
  expose it yourself.
- Models, chats, and settings are stored on-device only.
