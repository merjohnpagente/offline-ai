"""
FastAPI gateway for a local llama.cpp server.

Architecture:
    Flutter / OpenCode  ->  FastAPI :8080  ->  llama-server :8081  ->  GGUF

The gateway launches llama-server with your fine-tuned GGUF, exposes an
OpenAI-compatible /v1/chat/completions endpoint (streaming SSE preserved), a
simple /chat endpoint with in-memory history for the Flutter app, /health,
and /v1/models.

Environment variables:
    MODEL_PATH          Path to the GGUF file.
    LLAMA_SERVER_BIN    llama-server executable (default: llama-server).
    LLAMA_SERVER_URL    Use an already-running server instead of spawning one.
    LLAMA_PORT          Internal llama-server port (default: 8081).
    N_CTX               Context size (default: 8192).
    N_GPU_LAYERS        GPU layers to offload (default: 0 = CPU).
    THREADS             CPU threads (default: 8).
    SYSTEM_PROMPT_FILE  Optional text file used as the /chat system prompt.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

LOG = logging.getLogger("offline-ai")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = Path(
    os.environ.get(
        "MODEL_PATH",
        str(BASE_DIR / "models" / "qwen2.5-coder-7b-ft-Q4_K_M.gguf"),
    )
).expanduser()
LLAMA_SERVER_BIN = os.environ.get(
    "LLAMA_SERVER_BIN",
    "llama-server.exe" if sys.platform == "win32" else "llama-server",
)
LLAMA_SERVER_URL = os.environ.get("LLAMA_SERVER_URL", "").rstrip("/")
LLAMA_PORT = int(os.environ.get("LLAMA_PORT", "8081"))
N_CTX = int(os.environ.get("N_CTX", "8192"))
N_GPU_LAYERS = int(os.environ.get("N_GPU_LAYERS", "0"))
THREADS = int(os.environ.get("THREADS", "8"))
MODEL_ID = os.environ.get("MODEL_ID", "qwen2.5-coder-7b-ft")
MAX_HISTORY_MESSAGES = int(os.environ.get("MAX_HISTORY_MESSAGES", "12"))

DEFAULT_SYSTEM_PROMPT = """You are a private, offline coding assistant.
Be precise and practical. Prefer small, reviewable changes. When you show code,
include the file path and a complete runnable snippet. Never invent APIs or
commands. If information is missing, ask one focused question. Do not claim to
have run code or tests unless the result is actually present in the conversation.
"""

SYSTEM_PROMPT = DEFAULT_SYSTEM_PROMPT
prompt_file = os.environ.get("SYSTEM_PROMPT_FILE")
if prompt_file:
    SYSTEM_PROMPT = Path(prompt_file).read_text(encoding="utf-8").strip()

SESSIONS: dict[str, list[dict[str, str]]] = {}
SESSIONS_LOCK = asyncio.Lock()


class LlamaServer:
    def __init__(self) -> None:
        self.process: subprocess.Popen[str] | None = None
        self.log_file = None
        self.external = bool(LLAMA_SERVER_URL)

    @property
    def base_url(self) -> str:
        return LLAMA_SERVER_URL or f"http://127.0.0.1:{LLAMA_PORT}"

    def _resolve_binary(self) -> str:
        candidate = Path(LLAMA_SERVER_BIN)
        if candidate.is_file():
            return str(candidate)
        found = shutil.which(LLAMA_SERVER_BIN)
        if found:
            return found
        raise RuntimeError(
            f"Could not find '{LLAMA_SERVER_BIN}'. Install llama.cpp and put "
            "llama-server on PATH, or set LLAMA_SERVER_BIN to the full path. "
            "Download: https://github.com/ggml-org/llama.cpp/releases"
        )

    def start(self) -> None:
        if self.external:
            LOG.info("Using existing llama-server at %s", self.base_url)
            return

        if not MODEL_PATH.is_file():
            raise RuntimeError(
                f"Model not found: {MODEL_PATH}\n"
                "Copy your Q4_K_M GGUF into backend/models/ or set MODEL_PATH."
            )

        binary = self._resolve_binary()
        cmd = [
            binary,
            "-m",
            str(MODEL_PATH),
            "--host",
            "127.0.0.1",
            "--port",
            str(LLAMA_PORT),
            "-c",
            str(N_CTX),
            "-ngl",
            str(N_GPU_LAYERS),
            "-t",
            str(THREADS),
            "--jinja",
        ]
        LOG.info("Starting llama-server: %s", " ".join(cmd))
        self.log_file = open(BASE_DIR / "llama-server.log", "a", encoding="utf-8")
        self.process = subprocess.Popen(
            cmd,
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

    def wait_ready(self, timeout: float = 240.0) -> None:
        deadline = time.time() + timeout
        url = f"{self.base_url}/health"
        while time.time() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise RuntimeError(
                    "llama-server exited during startup. See backend/llama-server.log."
                )
            try:
                with httpx.Client(timeout=2.0) as client:
                    response = client.get(url)
                    if response.status_code == 200:
                        LOG.info("llama-server is ready at %s", self.base_url)
                        return
            except Exception:
                pass
            time.sleep(1.0)
        raise RuntimeError(f"Timed out waiting for llama-server at {url}")

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            LOG.info("Stopping llama-server")
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None


LLAMA = LlamaServer()


@asynccontextmanager
async def lifespan(_: FastAPI):
    LLAMA.start()
    LLAMA.wait_ready()
    yield
    LLAMA.stop()


app = FastAPI(
    title="Offline Coding Assistant",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

client = httpx.AsyncClient(
    timeout=httpx.Timeout(connect=10.0, read=None, write=60.0, pool=10.0)
)


class ChatIn(BaseModel):
    message: str = Field(min_length=1)
    session_id: str | None = None
    stream: bool = True


class Message(BaseModel):
    role: str
    content: Any = ""


class ChatCompletionIn(BaseModel):
    model: str = MODEL_ID
    messages: list[Message]
    stream: bool = True
    temperature: float = 0.2
    top_p: float = 0.95
    max_tokens: int = 1024


def upstream(path: str) -> str:
    return f"{LLAMA.base_url}{path}"


def sse_headers() -> dict[str, str]:
    return {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",
    }


async def get_history(session_id: str) -> list[dict[str, str]]:
    async with SESSIONS_LOCK:
        return list(SESSIONS.get(session_id, []))


async def add_turn(session_id: str, user: str, assistant: str) -> None:
    async with SESSIONS_LOCK:
        history = SESSIONS.setdefault(session_id, [])
        history.append({"role": "user", "content": user})
        history.append({"role": "assistant", "content": assistant})
        if len(history) > MAX_HISTORY_MESSAGES:
            del history[: len(history) - MAX_HISTORY_MESSAGES]


def extract_delta(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") or []
    if not choices:
        return ""
    choice = choices[0] or {}
    delta = choice.get("delta") or {}
    content = delta.get("content")
    if content:
        return str(content)
    message = choice.get("message") or {}
    content = message.get("content")
    if content:
        return str(content)
    return ""


async def proxy_sse(payload: dict[str, Any]) -> AsyncIterator[bytes]:
    try:
        async with client.stream(
            "POST",
            upstream("/v1/chat/completions"),
            json=payload,
            headers={"Content-Type": "application/json"},
        ) as response:
            if response.status_code >= 400:
                body = (await response.aread()).decode("utf-8", "replace")
                error = {
                    "error": {
                        "message": f"llama-server HTTP {response.status_code}: "
                        f"{body[:1000]}",
                        "type": "upstream_error",
                    }
                }
                yield f"data: {json.dumps(error)}\n\n".encode("utf-8")
                return
            async for chunk in response.aiter_raw():
                yield chunk
    except Exception as exc:
        error = {"error": {"message": str(exc), "type": "proxy_error"}}
        yield f"data: {json.dumps(error)}\n\n".encode("utf-8")


@app.get("/health")
async def health() -> JSONResponse:
    try:
        response = await client.get(upstream("/health"), timeout=5.0)
        upstream_ok = response.status_code == 200
        detail = response.text[:500]
    except Exception as exc:
        upstream_ok = False
        detail = str(exc)

    status = 200 if upstream_ok else 503
    return JSONResponse(
        status_code=status,
        content={
            "status": "ok" if upstream_ok else "degraded",
            "model": MODEL_ID,
            "model_path": str(MODEL_PATH),
            "llama_server": LLAMA.base_url,
            "upstream_ok": upstream_ok,
            "detail": detail,
        },
    )


@app.get("/v1/models")
async def models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_ID,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "local",
            }
        ],
    }


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    if not isinstance(body, dict) or "messages" not in body:
        raise HTTPException(status_code=400, detail="messages is required")

    body.setdefault("model", MODEL_ID)
    stream = bool(body.get("stream", True))

    if not stream:
        try:
            response = await client.post(
                upstream("/v1/chat/completions"),
                json=body,
                headers={"Content-Type": "application/json"},
            )
        except Exception as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return JSONResponse(
            status_code=response.status_code,
            content=response.json(),
        )

    return StreamingResponse(
        proxy_sse(body),
        media_type="text/event-stream",
        headers=sse_headers(),
    )


@app.post("/chat")
async def chat(body: ChatIn):
    session_id = body.session_id or uuid.uuid4().hex
    history = await get_history(session_id)
    messages: list[dict[str, str]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        *history,
        {"role": "user", "content": body.message},
    ]

    if not body.stream:
        payload = {
            "model": MODEL_ID,
            "messages": messages,
            "stream": False,
            "temperature": 0.2,
            "max_tokens": 1024,
        }
        try:
            response = await client.post(
                upstream("/v1/chat/completions"),
                json=payload,
                headers={"Content-Type": "application/json"},
            )
            response.raise_for_status()
            data = response.json()
            answer = data["choices"][0]["message"]["content"]
        except Exception as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        await add_turn(session_id, body.message, answer)
        return {"response": answer, "session_id": session_id}

    async def event_stream() -> AsyncIterator[bytes]:
        collected: list[str] = []
        payload = {
            "model": MODEL_ID,
            "messages": messages,
            "stream": True,
            "temperature": 0.2,
            "max_tokens": 1024,
        }
        try:
            async with client.stream(
                "POST",
                upstream("/v1/chat/completions"),
                json=payload,
                headers={"Content-Type": "application/json"},
            ) as response:
                if response.status_code >= 400:
                    body_text = (await response.aread()).decode("utf-8", "replace")
                    error = {
                        "error": f"llama-server HTTP {response.status_code}: "
                        f"{body_text[:1000]}"
                    }
                    yield f"data: {json.dumps(error)}\n\n".encode("utf-8")
                    return

                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if not data or data == "[DONE]":
                        continue
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    content = extract_delta(chunk)
                    if content:
                        collected.append(content)
                        yield (
                            "data: "
                            + json.dumps({"delta": content}, ensure_ascii=False)
                            + "\n\n"
                        ).encode("utf-8")

            answer = "".join(collected)
            await add_turn(session_id, body.message, answer)
            yield b"data: [DONE]\n\n"
        except Exception as exc:
            error = {"error": str(exc)}
            yield f"data: {json.dumps(error)}\n\n".encode("utf-8")

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers=sse_headers(),
    )


@app.get("/")
async def root() -> dict[str, str]:
    return {
        "name": "Offline Coding Assistant backend",
        "health": "/health",
        "chat": "/chat",
        "openai_compatible": "/v1/chat/completions",
        "models": "/v1/models",
    }
