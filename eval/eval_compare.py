#!/usr/bin/env python3
"""
eval_compare.py

Compare a BASE coding model and a FINE-TUNED coding model, both served through
local OpenAI-compatible endpoints, on held-out coding tasks.

What it measures per task:
  1. Syntax validity (Python ast.parse by default; optional tree-sitter for
     other languages).
  2. Exact match and fuzzy similarity against the reference solution.
  3. Optional pass@1 by running hidden tests in a subprocess.

It then prints a side-by-side table and a paired win/loss summary, including a
bootstrap confidence interval for the mean score delta and a sign test.

Dependencies:
    pip install requests
Optional:
    pip install tree-sitter tree-sitter-language-pack pytest

Example:
    python eval_compare.py \
      --tasks heldout_tasks.jsonl \
      --base-url http://127.0.0.1:11434/v1 \
      --base-model qwen2.5-coder:7b \
      --ft-url http://127.0.0.1:8081/v1 \
      --ft-model qwen2.5-coder-ft \
      --out eval_results

Security note:
    Hidden tests execute model-generated code. Run this in a disposable VM or
    container if you do not trust the models or the test file.
"""

from __future__ import annotations

import argparse
import ast
import csv
import importlib.util
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

try:
    import requests
except ImportError:
    sys.exit("Missing dependency: pip install requests")


SYSTEM_PROMPT = """You are a precise Python coding assistant.
Return ONLY the complete, runnable Python code in one ```python fenced block.
Do not include explanations, examples, or test code.
Include every import the solution needs.
Do not call input() or read from stdin.
The code must be importable as a module."""


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Task:
    id: str
    prompt: str
    expected: str
    tests: str | None = None
    language: str = "python"


@dataclass
class Result:
    task_id: str
    model: str
    response: str
    code: str
    syntax_ok: bool | None
    syntax_error: str | None
    exact: bool
    fuzzy: float
    tests_ok: bool | None
    test_output: str
    score: float
    latency_s: float
    error: str | None = None


# ---------------------------------------------------------------------------
# Loading and code extraction
# ---------------------------------------------------------------------------

def load_tasks(path: Path, default_language: str = "python") -> list[Task]:
    tasks: list[Task] = []
    with path.open("r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}") from exc
            if "prompt" not in row or "expected" not in row:
                raise SystemExit(
                    f"{path}:{line_no}: every row needs 'prompt' and 'expected'"
                )
            tests = row.get("tests", row.get("test"))
            if isinstance(tests, list):
                tests = "\n".join(str(t) for t in tests)
            tasks.append(
                Task(
                    id=str(row.get("id") or f"task_{len(tasks) + 1:02d}"),
                    prompt=str(row["prompt"]),
                    expected=str(row["expected"]),
                    tests=str(tests) if tests else None,
                    language=str(row.get("language", default_language)),
                )
            )
    if not tasks:
        raise SystemExit(f"No tasks found in {path}")
    return tasks


def extract_code(text: str) -> str:
    """Extract the largest Python fenced block, else fall back to a code heuristic."""
    if not text:
        return ""

    # Prefer explicitly Python-tagged fences.
    py_blocks = re.findall(
        r"```[ \t]*(?:python|py|python3)[ \t]*\r?\n(.*?)```",
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    if py_blocks:
        return max(py_blocks, key=len).strip()

    # Then any fenced block.
    any_blocks = re.findall(
        r"```[^\n]*\r?\n(.*?)```",
        text,
        flags=re.DOTALL,
    )
    if any_blocks:
        return max(any_blocks, key=len).strip()

    # No fence: start at the first likely code line.
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*(?:import\s|from\s|def\s|class\s|@|#!|async\s+def\s)", line):
            start = i
            break
    if start is not None:
        return "\n".join(lines[start:]).strip()
    return text.strip()


def normalize_code(code: str, language: str = "python") -> str:
    """Normalize formatting so exact/fuzzy matching is about content, not whitespace."""
    code = (code or "").strip()
    if not code:
        return ""
    if language.lower() in {"python", "py"}:
        try:
            return ast.unparse(ast.parse(code))
        except (SyntaxError, ValueError):
            pass
    # Fallback: collapse whitespace, drop blank lines.
    lines = []
    for line in code.splitlines():
        line = re.sub(r"[ \t]+", " ", line).strip()
        if line:
            lines.append(line)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def syntax_check(code: str, language: str) -> tuple[bool | None, str | None]:
    if not code.strip():
        return False, "empty code"

    if language.lower() in {"python", "py"}:
        try:
            ast.parse(code)
            return True, None
        except (SyntaxError, ValueError) as exc:
            if isinstance(exc, SyntaxError):
                return False, f"{exc.msg} (line {exc.lineno}, column {exc.offset})"
            return False, str(exc)

    # Optional tree-sitter support for non-Python tasks.
    if importlib.util.find_spec("tree_sitter_language_pack") is None:
        return None, "tree-sitter-language-pack not installed"
    try:
        from tree_sitter_language_pack import get_parser  # type: ignore

        parser = get_parser(language)
        tree = parser.parse(code.encode("utf-8"))
        if tree.root_node.has_error:
            return False, "tree-sitter reported a parse error"
        return True, None
    except Exception as exc:  # noqa: BLE001 - optional dependency boundary
        return None, f"tree-sitter unavailable: {exc}"


def fuzzy_score(candidate: str, expected: str, language: str) -> float:
    a = normalize_code(candidate, language)
    b = normalize_code(expected, language)
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b, autojunk=False).ratio()


def run_hidden_tests(
    code: str,
    tests: str | None,
    timeout: float = 10.0,
) -> tuple[bool | None, str]:
    """Run hidden tests in a temporary directory. Returns (passed, output)."""
    if not tests:
        return None, ""
    if not code.strip():
        return False, "empty code"

    with tempfile.TemporaryDirectory(prefix="coding_eval_") as tmp:
        tmp_path = Path(tmp)
        (tmp_path / "candidate.py").write_text(code, encoding="utf-8")

        test_source = (
            "import os, sys\n"
            "sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))\n"
            "from candidate import *\n\n"
            + tests
            + "\n"
        )
        (tmp_path / "test_candidate.py").write_text(test_source, encoding="utf-8")

        # Keep the environment small; do not pass API keys or other secrets.
        keep = ("PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "TEMP", "TMP")
        env = {k: os.environ[k] for k in keep if k in os.environ}
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"

        use_pytest = "def test_" in tests or "import pytest" in tests
        if use_pytest:
            if importlib.util.find_spec("pytest") is None:
                return False, "pytest-style tests found but pytest is not installed"
            cmd = [sys.executable, "-m", "pytest", "-q", "test_candidate.py"]
        else:
            cmd = [sys.executable, "-I", "test_candidate.py"]

        try:
            proc = subprocess.run(
                cmd,
                cwd=str(tmp_path),
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return False, f"TIMEOUT after {timeout:g}s"

        output = (proc.stdout + "\n" + proc.stderr).strip()
        return proc.returncode == 0, output[-4000:]


def compute_score(result: Result) -> float:
    """Weighted score. Hidden tests dominate when they exist."""
    if result.syntax_ok is True:
        syntax = 1.0
    elif result.syntax_ok is False:
        syntax = 0.0
    else:
        syntax = 0.5  # unsupported language: neither reward nor punish

    if result.tests_ok is not None:
        tests = 1.0 if result.tests_ok else 0.0
        return 0.10 * syntax + 0.20 * result.fuzzy + 0.70 * tests
    return 0.40 * syntax + 0.60 * result.fuzzy


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------

def chat_url(base_url: str) -> str:
    url = base_url.rstrip("/")
    if url.endswith("/chat/completions"):
        return url
    if url.endswith("/v1"):
        return url + "/chat/completions"
    return url + "/v1/chat/completions"


def models_url(base_url: str) -> str:
    url = base_url.rstrip("/")
    if url.endswith("/chat/completions"):
        url = url[: -len("/chat/completions")]
    if url.endswith("/v1"):
        return url + "/models"
    return url + "/v1/models"


def check_models(
    session: requests.Session,
    base_url: str,
    api_key: str,
    timeout: float = 10.0,
) -> tuple[bool, str]:
    try:
        response = session.get(
            models_url(base_url),
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=timeout,
        )
        if response.status_code >= 400:
            return False, f"HTTP {response.status_code}: {response.text[:300]}"
        data = response.json()
        ids = [str(m.get("id")) for m in data.get("data", []) if m.get("id")]
        return True, ", ".join(ids[:10]) or "(no model ids returned)"
    except Exception as exc:  # noqa: BLE001 - health check should not crash the run
        return False, str(exc)


class EndpointError(RuntimeError):
    """A configuration/HTTP error that should not be retried."""


def call_chat(
    session: requests.Session,
    base_url: str,
    model: str,
    prompt: str,
    api_key: str,
    temperature: float,
    max_tokens: int,
    timeout: float,
    seed: int | None,
) -> tuple[str, dict[str, Any]]:
    payload: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
    }
    if seed is not None:
        payload["seed"] = seed

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }

    last_error: Exception | None = None
    for attempt in range(3):
        try:
            response = session.post(
                chat_url(base_url),
                json=payload,
                headers=headers,
                timeout=(10.0, timeout),
            )

            # Some servers reject the optional seed field. Retry once without it.
            if response.status_code == 400 and "seed" in payload:
                payload.pop("seed", None)
                response = session.post(
                    chat_url(base_url),
                    json=payload,
                    headers=headers,
                    timeout=(10.0, timeout),
                )

            if response.status_code == 404:
                raise EndpointError(
                    f"HTTP 404 from {chat_url(base_url)}. "
                    "Check the base URL and that the model name exists."
                )
            if response.status_code in {400, 401, 403}:
                raise EndpointError(
                    f"HTTP {response.status_code} from {chat_url(base_url)}: "
                    f"{response.text[:500]}"
                )
            response.raise_for_status()
            data = response.json()
            choices = data.get("choices") or []
            if not choices:
                raise RuntimeError(f"No choices in response: {str(data)[:500]}")

            message = choices[0].get("message") or {}
            content = message.get("content")
            if content is None:
                content = choices[0].get("text", "")

            # Some OpenAI-compatible servers return content as parts.
            if isinstance(content, list):
                content = "".join(
                    str(part.get("text", ""))
                    for part in content
                    if isinstance(part, dict)
                )
            return str(content or ""), data
        except EndpointError:
            raise
        except Exception as exc:  # noqa: BLE001 - retry boundary
            last_error = exc
            if attempt < 2:
                time.sleep(2**attempt)

    raise RuntimeError(f"Request failed after 3 attempts: {last_error}")


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

def evaluate_one(
    session: requests.Session,
    task: Task,
    base_url: str,
    model: str,
    args: argparse.Namespace,
) -> Result:
    started = time.perf_counter()
    response = ""
    error = None
    try:
        response, _ = call_chat(
            session=session,
            base_url=base_url,
            model=model,
            prompt=task.prompt,
            api_key=args.api_key,
            temperature=args.temperature,
            max_tokens=args.max_tokens,
            timeout=args.timeout,
            seed=args.seed,
        )
    except Exception as exc:  # noqa: BLE001 - record and continue
        error = str(exc)
    latency = time.perf_counter() - started

    code = extract_code(response)
    syntax_ok, syntax_error = syntax_check(code, task.language)
    exact = bool(code) and normalize_code(code, task.language) == normalize_code(
        task.expected, task.language
    )
    fuzzy = fuzzy_score(code, task.expected, task.language)

    tests = None if args.no_hidden_tests else task.tests
    if error:
        tests_ok = False if tests else None
        test_output = f"not run: {error}"
    else:
        tests_ok, test_output = run_hidden_tests(code, tests, timeout=args.test_timeout)

    result = Result(
        task_id=task.id,
        model=model,
        response=response,
        code=code,
        syntax_ok=syntax_ok,
        syntax_error=syntax_error,
        exact=exact,
        fuzzy=fuzzy,
        tests_ok=tests_ok,
        test_output=test_output,
        score=0.0,
        latency_s=latency,
        error=error,
    )
    result.score = compute_score(result)
    return result


def decide_winner(base: Result, ft: Result, margin: float) -> str:
    # Hidden-test result is the strongest signal.
    if base.tests_ok is not None and ft.tests_ok is not None:
        if base.tests_ok != ft.tests_ok:
            return "fine-tuned" if ft.tests_ok else "base"

    delta = ft.score - base.score
    if delta >= margin:
        return "fine-tuned"
    if delta <= -margin:
        return "base"
    return "tie"


def bootstrap_ci(deltas: list[float], samples: int = 5000, seed: int = 42) -> tuple[float, float]:
    if not deltas or samples <= 0:
        return 0.0, 0.0
    rng = random.Random(seed)
    n = len(deltas)
    means = []
    for _ in range(samples):
        total = 0.0
        for _ in range(n):
            total += deltas[rng.randrange(n)]
        means.append(total / n)
    means.sort()
    lo = means[int(0.025 * samples)]
    hi = means[max(0, int(0.975 * samples) - 1)]
    return lo, hi


def sign_test_two_sided(wins: int, losses: int) -> float:
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / (2**n)
    return min(1.0, 2.0 * tail)


def fmt_bool(value: bool | None) -> str:
    if value is True:
        return "Y"
    if value is False:
        return "N"
    return "-"


def print_table(rows: list[tuple[Task, Result, Result, str, float]]) -> None:
    headers = [
        "Task",
        "B syn",
        "B exact",
        "B fuzzy",
        "B test",
        "B score",
        "F syn",
        "F exact",
        "F fuzzy",
        "F test",
        "F score",
        "Winner",
        "Delta",
    ]
    table: list[list[str]] = [headers]
    for task, base, ft, winner, delta in rows:
        table.append(
            [
                task.id,
                fmt_bool(base.syntax_ok),
                fmt_bool(base.exact),
                f"{base.fuzzy:.2f}",
                fmt_bool(base.tests_ok),
                f"{base.score:.3f}",
                fmt_bool(ft.syntax_ok),
                fmt_bool(ft.exact),
                f"{ft.fuzzy:.2f}",
                fmt_bool(ft.tests_ok),
                f"{ft.score:.3f}",
                {"fine-tuned": "FT", "base": "BASE", "tie": "tie"}[winner],
                f"{delta:+.3f}",
            ]
        )

    widths = [max(len(row[i]) for row in table) for i in range(len(headers))]
    line = "+" + "+".join("-" * (w + 2) for w in widths) + "+"
    print(line)
    for row_index, row in enumerate(table):
        cells = [f" {cell:<{widths[i]}} " for i, cell in enumerate(row)]
        print("|" + "|".join(cells) + "|")
        if row_index == 0:
            print(line)
    print(line)


def save_results(
    out_dir: Path,
    args: argparse.Namespace,
    tasks: list[Task],
    rows: list[tuple[Task, Result, Result, str, float]],
    summary: dict[str, Any],
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    payload = {
        "config": {
            "base_url": args.base_url,
            "base_model": args.base_model,
            "ft_url": args.ft_url,
            "ft_model": args.ft_model,
            "temperature": args.temperature,
            "max_tokens": args.max_tokens,
            "seed": args.seed,
            "win_margin": args.win_margin,
            "hidden_tests": not args.no_hidden_tests,
        },
        "summary": summary,
        "tasks": [
            {
                "task": asdict(task),
                "base": asdict(base),
                "fine_tuned": asdict(ft),
                "winner": winner,
                "delta": delta,
            }
            for task, base, ft, winner, delta in rows
        ],
    }
    (out_dir / "results.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    with (out_dir / "results.csv").open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "task_id",
                "base_syntax",
                "base_exact",
                "base_fuzzy",
                "base_tests",
                "base_score",
                "ft_syntax",
                "ft_exact",
                "ft_fuzzy",
                "ft_tests",
                "ft_score",
                "winner",
                "delta",
            ]
        )
        for task, base, ft, winner, delta in rows:
            writer.writerow(
                [
                    task.id,
                    fmt_bool(base.syntax_ok),
                    fmt_bool(base.exact),
                    f"{base.fuzzy:.4f}",
                    fmt_bool(base.tests_ok),
                    f"{base.score:.4f}",
                    fmt_bool(ft.syntax_ok),
                    fmt_bool(ft.exact),
                    f"{ft.fuzzy:.4f}",
                    fmt_bool(ft.tests_ok),
                    f"{ft.score:.4f}",
                    winner,
                    f"{delta:+.4f}",
                ]
            )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare base vs fine-tuned local coding models on held-out tasks.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--tasks", required=True, type=Path, help="Held-out tasks JSONL")
    parser.add_argument("--base-url", default="http://127.0.0.1:11434/v1")
    parser.add_argument("--base-model", required=True, help="Ollama/base model name")
    parser.add_argument("--ft-url", default="http://127.0.0.1:8081/v1")
    parser.add_argument("--ft-model", required=True, help="Fine-tuned model name")
    parser.add_argument("--api-key", default="local", help="Any non-empty key for local servers")
    parser.add_argument("--out", type=Path, default=Path("eval_results"))
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--timeout", type=float, default=300.0, help="Read timeout per request")
    parser.add_argument("--test-timeout", type=float, default=10.0)
    parser.add_argument("--win-margin", type=float, default=0.05)
    parser.add_argument("--bootstrap", type=int, default=5000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--language", default="python", help="Default task language")
    parser.add_argument(
        "--no-hidden-tests",
        action="store_true",
        help="Ignore the optional 'tests' field; score with syntax/fuzzy only",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    tasks = load_tasks(args.tasks, default_language=args.language)
    if len(tasks) != 20:
        print(
            f"WARNING: expected 20 held-out tasks, found {len(tasks)}. "
            "Results will be noisier.",
            file=sys.stderr,
        )

    session = requests.Session()

    print("Endpoint health check:")
    for label, url, model in (
        ("base", args.base_url, args.base_model),
        ("fine-tuned", args.ft_url, args.ft_model),
    ):
        ok, message = check_models(session, url, args.api_key)
        status = "OK" if ok else "WARN"
        print(f"  [{status}] {label:10s} {url}  model={model}  {message}", flush=True)
        if not ok:
            print(
                "       -> check the server is running, the URL ends in /v1, "
                "and the model name is correct",
                flush=True,
            )
    print(flush=True)

    rows: list[tuple[Task, Result, Result, str, float]] = []
    for index, task in enumerate(tasks, 1):
        print(f"[{index:02d}/{len(tasks)}] {task.id}", file=sys.stderr, flush=True)
        base = evaluate_one(session, task, args.base_url, args.base_model, args)
        ft = evaluate_one(session, task, args.ft_url, args.ft_model, args)
        winner = decide_winner(base, ft, args.win_margin)
        delta = ft.score - base.score
        rows.append((task, base, ft, winner, delta))

    print("\nPer-task results (B=base, F=fine-tuned, Y/N/- = pass/fail/skipped)\n")
    print_table(rows)

    wins = sum(1 for _, _, _, winner, _ in rows if winner == "fine-tuned")
    losses = sum(1 for _, _, _, winner, _ in rows if winner == "base")
    ties = len(rows) - wins - losses
    deltas = [delta for _, _, _, _, delta in rows]
    base_scores = [base.score for _, base, _, _, _ in rows]
    ft_scores = [ft.score for _, _, ft, _, _ in rows]
    base_mean = sum(base_scores) / len(base_scores)
    ft_mean = sum(ft_scores) / len(ft_scores)
    mean_delta = ft_mean - base_mean
    ci_low, ci_high = bootstrap_ci(deltas, samples=args.bootstrap, seed=args.seed)
    p_value = sign_test_two_sided(wins, losses)

    tested = [row for row in rows if row[1].tests_ok is not None]
    base_test_pass = sum(1 for _, base, _, _, _ in tested if base.tests_ok)
    ft_test_pass = sum(1 for _, _, ft, _, _ in tested if ft.tests_ok)
    base_syntax_pass = sum(1 for _, base, _, _, _ in rows if base.syntax_ok)
    ft_syntax_pass = sum(1 for _, _, ft, _, _ in rows if ft.syntax_ok)
    base_exact = sum(1 for _, base, _, _, _ in rows if base.exact)
    ft_exact = sum(1 for _, _, ft, _, _ in rows if ft.exact)

    print("\nSummary")
    print(f"  Tasks:                 {len(rows)}")
    print(f"  Base mean score:       {base_mean:.3f}")
    print(f"  Fine-tuned mean score: {ft_mean:.3f}")
    print(f"  Mean delta (FT-Base):  {mean_delta:+.3f}")
    print(f"  95% bootstrap CI:      [{ci_low:+.3f}, {ci_high:+.3f}]")
    print(f"  Wins / losses / ties:  {wins} / {losses} / {ties}")
    print(f"  Sign test p-value:     {p_value:.4f}")
    print(f"  Syntax pass:           base {base_syntax_pass}/{len(rows)}  ft {ft_syntax_pass}/{len(rows)}")
    print(f"  Exact match:           base {base_exact}/{len(rows)}  ft {ft_exact}/{len(rows)}")
    if tested:
        print(
            f"  Hidden-test pass@1:    base {base_test_pass}/{len(tested)}  "
            f"ft {ft_test_pass}/{len(tested)}"
        )
    else:
        print("  Hidden-test pass@1:    not available (no tests, or --no-hidden-tests)")

    summary = {
        "tasks": len(rows),
        "base_mean_score": base_mean,
        "ft_mean_score": ft_mean,
        "mean_delta": mean_delta,
        "ci95_low": ci_low,
        "ci95_high": ci_high,
        "wins": wins,
        "losses": losses,
        "ties": ties,
        "sign_test_p": p_value,
        "base_syntax_pass": base_syntax_pass,
        "ft_syntax_pass": ft_syntax_pass,
        "base_exact": base_exact,
        "ft_exact": ft_exact,
        "base_hidden_test_pass": base_test_pass if tested else None,
        "ft_hidden_test_pass": ft_test_pass if tested else None,
        "hidden_test_tasks": len(tested),
    }
    save_results(args.out, args, tasks, rows, summary)
    print(f"\nSaved: {args.out / 'results.json'} and {args.out / 'results.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
