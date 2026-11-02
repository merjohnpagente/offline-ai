# One-time model download for the on-device Flutter app.
# The app itself never downloads anything.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root "flutter_app\assets\models"
$out = Join-Path $outDir "model.gguf"
$url = "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true"
$expected = "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (Test-Path $out) {
    $existing = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
    if ($existing -eq $expected) {
        Write-Host "Model already present and verified: $out"
        exit 0
    }
    Write-Host "Existing file does not match; replacing it."
    Remove-Item -Force $out
}

Write-Host "Downloading Qwen2.5-Coder-1.5B-Instruct Q4_K_M (~1.1 GB)..."
Invoke-WebRequest -Uri $url -OutFile $out

$actual = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) {
    Remove-Item -Force $out
    throw "SHA-256 mismatch. Expected $expected, got $actual"
}

Write-Host "Saved and verified: $out"
