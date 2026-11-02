# Bundled model

Put the GGUF that should ship inside the APK here, named exactly:

```
model.gguf
```

The default helper downloads the official Apache-2.0
`Qwen2.5-Coder-1.5B-Instruct` Q4_K_M model (about 1.1 GB):

```powershell
powershell -ExecutionPolicy Bypass -File tools/fetch_model.ps1
```

or:

```bash
bash tools/fetch_model.sh
```

After you fine-tune your own model, replace this file with your merged and
quantized GGUF (also named `model.gguf`) and rebuild.

The model is copied into private app storage on first launch. The Android app
has no `INTERNET` permission, so the final app cannot use Wi-Fi even by mistake.
