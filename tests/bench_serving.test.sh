#!/usr/bin/env bash
# bench_serving.test.sh —— bench_serving.sh 网格输出契约(fake sglang.bench_serving)
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AUTO_WORK=$(cd -- "$TEST_DIR/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# fake python module: python3 -m sglang.bench_serving
PYMOD="$TMP/pymod"
mkdir -p "$PYMOD/sglang"
touch "$PYMOD/sglang/__init__.py"
cat >"$PYMOD/sglang/bench_serving.py" <<'EOF'
import argparse
import json

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--output-file", required=True)
    p.add_argument("--tokenizer", default=None)
    ns, _ = p.parse_known_args()
    lines = [
        "Traffic request rate: inf",
        "Successful requests: 2",
        "Peak concurrent requests: 2",
        "Benchmark duration: 1.25",
        "Request throughput: 1.60",
        "Output token throughput: 100.00",
        "Total token throughput: 500.00",
        "Peak output token throughput: 120.00",
        "Mean TTFT (ms): 10.00",
        "P95 TTFT (ms): 12.00",
        "P99 TTFT (ms): 13.00",
        "Mean TPOT (ms): 4.00",
        "P95 TPOT (ms): 5.00",
        "P99 TPOT (ms): 6.00",
        "Mean ITL (ms): 3.00",
        "P95 ITL (ms): 4.00",
        "P99 ITL (ms): 5.00",
    ]
    for ln in lines:
        print(ln)
    with open(ns.output_file, "w", encoding="utf-8") as f:
        f.write(json.dumps({"ok": 1}) + "\n")

if __name__ == "__main__":
    main()
EOF

# 模型目录(本地 tokenizer 契约)
MODEL_DIR="$TMP/model"
mkdir -p "$MODEL_DIR"
touch "$MODEL_DIR/config.json"

export MODEL_NAME="Qwen"
export MODEL_PATH="$MODEL_DIR"
export HOST="127.0.0.1"
export PORT="30123"
export RUN_DIR="$TMP/out"
export BENCH_PAIRS="16 4"
export BENCH_CONCURRENCIES="2"
export CONCURRENCY_MULTIPLIER="1"
mkdir -p "$RUN_DIR"

PYTHONPATH="$PYMOD${PYTHONPATH:+:$PYTHONPATH}" bash "$AUTO_WORK/lib/bench_serving.sh" >"$TMP/bench.log" 2>&1

# 产物命名 + jsonl 不散落
[[ -f "$RUN_DIR/all.csv" ]] || { echo "FAIL: all.csv 缺失"; exit 1; }
[[ -f "$RUN_DIR/Qwen-2-in16-out4.log" ]] || { echo "FAIL: 组合 .log 缺失"; exit 1; }
[[ -f "$RUN_DIR/Qwen-2-in16-out4.jsonl" ]] || { echo "FAIL: 组合 .jsonl 缺失"; exit 1; }
(ls "$PYMOD"/*.jsonl >/dev/null 2>&1) && { echo "FAIL: jsonl 散落到脚本目录"; exit 1; }
(ls "$(dirname "$(readlink -f "$AUTO_WORK/lib/bench_serving.sh")")"/*.jsonl >/dev/null 2>&1) && { echo "FAIL: jsonl 散落到 lib"; exit 1; }

HEADER=$(head -n 1 "$RUN_DIR/all.csv")
EXPECT_HEADER="input,output,request_rate,num_prompts,max_concurrency,concurrency,Peak_concurrent_requests,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,Peak_output_token_throughput,mean_ttft_ms,p95_ttft_ms,p99_ttft_ms,mean_tpot_ms,p95_tpot_ms,p99_tpot_ms,mean_itl_ms,p95_itl_ms,p99_itl_ms"
[[ "$HEADER" == "$EXPECT_HEADER" ]] || { echo "FAIL: 表头不符"; exit 1; }
LINES=$(wc -l <"$RUN_DIR/all.csv")
[[ "$LINES" == "2" ]] || { echo "FAIL: 期望 1 表头+1 数据行,实际 $LINES 行"; exit 1; }
DATA=$(tail -n +2 "$RUN_DIR/all.csv")
EXPECT_DATA="16,4,inf,2,2,2,2,1.25,1.60,100.00,500.00,120.00,10.00,12.00,13.00,4.00,5.00,6.00,3.00,4.00,5.00"
[[ "$DATA" == "$EXPECT_DATA" ]] || { echo "FAIL: 数据行不符: $DATA"; exit 1; }

echo "bench_serving.test.sh: OK"
