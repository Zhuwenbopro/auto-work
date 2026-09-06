#!/usr/bin/env bash
# eval_command.test.sh —— eval_command.sh 调用形状回归(fake evalscope,不碰服务)
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AUTO_WORK=$(cd -- "$TEST_DIR/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 假模型目录(本地路径即 eval 的 --model 契约)
MODEL_DIR="$TMP/model"
mkdir -p "$MODEL_DIR"
touch "$MODEL_DIR/config.json"

# fake evalscope:把收到的 argv 原样逐行写入 CALLS 文件
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/evalscope" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FAKE_CALLS:?FAKE_CALLS required}"
EOF
chmod +x "$FAKE_BIN/evalscope"
export FAKE_CALLS="$TMP/calls.txt"

export MODEL_PATH="$MODEL_DIR"
export HEALTH_HOST="127.0.0.1"
export PORT="30123"
export RUN_DIR="$TMP/rundir"
export EVAL_LOG="$TMP/rundir/eval.log"
export EVAL_ENABLE_THINKING="false"
export EVAL_DATASETS="humaneval"
export EVAL_BATCH="64"
export EVAL_LIMIT="None"
mkdir -p "$RUN_DIR"

# eval_command 有 set -e;失败要能看到输出,不用 set +e 包一层就让它自然失败
PATH="$FAKE_BIN:$PATH" bash "$AUTO_WORK/lib/eval_command.sh" >"$EVAL_LOG" 2>&1

python3 - "$TMP/calls.txt" "$MODEL_DIR" <<'PY' || { echo "FAIL: 调用形状不符"; exit 1; }
import json
import sys
args = open(sys.argv[1], encoding="utf-8").read().splitlines()
model_dir = sys.argv[2]

def value_of(flag):
    try:
        i = args.index(flag)
    except ValueError:
        raise AssertionError(f"缺少参数 {flag}: {args}")
    return args[i + 1]

assert value_of("--model") == model_dir
assert value_of("--api-url") == "http://127.0.0.1:30123/v1"
assert value_of("--api-key") == "EMPTY"
assert value_of("--eval-type") == "openai_api"
assert value_of("--eval-batch-size") == "64"
# 单数据集单参数(--datasets 每个数据集一个参数)
assert "--datasets" in args
assert value_of("--datasets") == "humaneval"
assert "--limit" not in args, "EVAL_LIMIT=None 不应带 --limit"
cfg = json.loads(value_of("--generation-config"))
assert cfg["max_tokens"] == 4096, "humaneval 覆盖应为 max_tokens=4096"
assert cfg["extra_body"]["chat_template_kwargs"]["enable_thinking"] is False
da = json.loads(value_of("--dataset-args"))
assert da["humaneval"]["review_timeout"] == 30
assert da["humaneval"]["filters"]["remove_until"] == "</think>"
PY

echo "eval_command.test.sh: OK"
