#!/usr/bin/env python3
"""Start FastAPI + llama-server and verify /health and /v1/models."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
MODEL_PATH = Path(
    os.environ.get(
        "MODEL_PATH",
        str(BASE_DIR / "models" / "qwen2.5-coder-7b-ft-Q4_K_M.gguf"),
    )
).expanduser()
LLAMA_SERVER_URL = os.environ.get("LLAMA_SERVER_URL", "").strip()
LLAMA_SERVER_BIN = os.environ.get(
    "LLAMA_SERVER_BIN",
    "llama-server.exe" if sys.platform == "win32" else "llama-server",
)


def lan_ip() -> str:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        return ip
    except OSError:
        return "127.0.0.1"


def wait_for(url: str, timeout: float = 240.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        time.sleep(1.5)
    return False


def main() -> int:
    if not LLAMA_SERVER_URL:
        if not MODEL_PATH.is_file():
            print(f"Model not found: {MODEL_PATH}")
            print("Put your Q4_K_M GGUF in backend/models/ or set MODEL_PATH.")
            return 1
        if os.path.sep not in LLAMA_SERVER_BIN and not os.path.exists(LLAMA_SERVER_BIN):
            # shutil.which is more reliable, but this keeps the script dependency-free.
            from shutil import which

            if which(LLAMA_SERVER_BIN) is None:
                print(f"llama-server not found: {LLAMA_SERVER_BIN}")
                print("Download llama.cpp binaries:")
                print("https://github.com/ggml-org/llama.cpp/releases")
                print("Then set LLAMA_SERVER_BIN to the full path if needed.")
                return 1

    env = os.environ.copy()
    env.setdefault("MODEL_PATH", str(MODEL_PATH))
    cmd = [
        sys.executable,
        "-m",
        "uvicorn",
        "app:app",
        "--host",
        HOST,
        "--port",
        str(PORT),
    ]
    print("Starting:", " ".join(cmd))
    process = subprocess.Popen(cmd, cwd=str(BASE_DIR), env=env)
    try:
        health = f"http://127.0.0.1:{PORT}/health"
        models = f"http://127.0.0.1:{PORT}/v1/models"
        print("Waiting for the model to load (first start can take a few minutes)...")
        if not wait_for(health):
            print("Backend did not become healthy. Check backend/llama-server.log.")
            process.terminate()
            return 1
        with urllib.request.urlopen(models, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
        print("\nBackend is ready.")
        print(f"  Local:   http://127.0.0.1:{PORT}")
        print(f"  LAN:     http://{lan_ip()}:{PORT}")
        print(f"  Models:  {models}")
        print(f"  Models response: {json.dumps(payload)[:300]}")
        print("\nFlutter settings -> backend URL:", f"http://{lan_ip()}:{PORT}")
        print("Press Ctrl+C to stop.")
        process.wait()
        return process.returncode or 0
    except KeyboardInterrupt:
        print("\nStopping...")
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
