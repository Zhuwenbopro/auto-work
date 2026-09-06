#!/usr/bin/env python3
"""Capture one short SGLang Torch Profiler trace."""

from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request_json(url: str, payload: dict | None, timeout: int) -> dict | str:
    data = None if payload is None else json.dumps(payload).encode()
    request = Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
        method="POST" if data else "GET",
    )
    with urlopen(request, timeout=timeout) as response:
        body = response.read().decode()
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body


def call_profile(base_url: str, endpoint: str, payload: dict | None, timeout: int) -> dict | str:
    try:
        return request_json(f"{base_url}{endpoint}", payload, timeout)
    except (HTTPError, URLError, TimeoutError) as exc:
        raise RuntimeError(f"{endpoint} failed: {exc}") from exc


def wait_for_trace(output_dir: Path, timeout: int) -> list[Path]:
    deadline = time.monotonic() + timeout
    patterns = ("*.trace.json.gz", "*.trace.json", "*.json")
    while time.monotonic() < deadline:
        traces = sorted(
            {
                path
                for pattern in patterns
                for path in output_dir.rglob(pattern)
                if path.name != "server_args.json" and path.stat().st_size > 0
            }
        )
        if traces:
            return traces
        time.sleep(2)
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--input-len", type=int, default=4096)
    parser.add_argument("--output-len", type=int, default=3)
    parser.add_argument("--warmup-output-len", type=int, default=1)
    parser.add_argument("--request-timeout", type=int, default=600)
    parser.add_argument("--trace-timeout", type=int, default=180)
    args = parser.parse_args()

    if args.input_len <= 0 or args.output_len <= 0 or args.warmup_output_len <= 0:
        raise SystemExit("lengths must be positive")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex
    warmup_prompt = f"warmup-{run_id} " + "warmup " * (args.input_len - 1)
    profile_prompt = f"profile-{run_id} " + "profile " * (args.input_len - 1)
    warmup_payload = {
        "text": warmup_prompt,
        "sampling_params": {"temperature": 0, "max_new_tokens": args.warmup_output_len},
    }
    profile_payload = {
        "output_dir": str(args.output_dir),
        "num_steps": 3,
        "activities": ["CPU", "GPU"],
        "profile_by_stage": False,
        "merge_profiles": False,
        "profile_prefix": "prefill1-decode2",
    }

    print("warmup request started", flush=True)
    request_json(f"{args.url}/generate", warmup_payload, args.request_timeout)
    print("warmup request completed", flush=True)

    profiler_started = False
    try:
        print("starting profiler: num_steps=3", flush=True)
        call_profile(args.url, "/start_profile", profile_payload, args.request_timeout)
        profiler_started = True
        request_json(
            f"{args.url}/generate",
            {
                "text": profile_prompt,
                "sampling_params": {
                    "temperature": 0,
                    "max_new_tokens": args.output_len,
                },
            },
            args.request_timeout,
        )
        print("profile request completed", flush=True)
    finally:
        if profiler_started:
            try:
                call_profile(args.url, "/stop_profile", {}, args.request_timeout)
                print("profiler stopped", flush=True)
            except RuntimeError as exc:
                print(f"warning: {exc}", file=sys.stderr, flush=True)

    traces = wait_for_trace(args.output_dir, args.trace_timeout)
    if not traces:
        print(f"no trace found within {args.trace_timeout}s", file=sys.stderr)
        return 2
    for trace in traces:
        print(f"trace: {trace}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"profile failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
