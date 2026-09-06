#!/usr/bin/env bash
# run_common.test.sh —— run_common.sh 契约测试(不碰 GPU/服务)
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AUTO_WORK=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck source=/dev/null
source "$AUTO_WORK/lib/run_common.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) write_json_file + read_started_json + numeric 转换
write_json_file "$TMP/started.json" \
  result ok pid 12345 pgid 12345 port 30123 gpus_csv "0,2" \
  health_url "http://127.0.0.1:30123/health" \
  server_log "$TMP/server.log" run_dir "$TMP" \
  model_name "Qwen3-8B" model_path "/models/Qwen3-8B" \
  elapsed_s 7

python3 - "$TMP/started.json" <<'PY' || { echo "FAIL: numeric 转换"; exit 1; }
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj["pid"] == 12345 and isinstance(obj["pid"], int)
assert obj["elapsed_s"] == 7
assert obj["model_path"] == "/models/Qwen3-8B"
PY

read_started_json "$TMP/started.json"
[[ "$STARTED_PORT" == "30123" ]] || { echo "FAIL: port=$STARTED_PORT"; exit 1; }
[[ "$STARTED_MODEL_PATH" == "/models/Qwen3-8B" ]] || { echo "FAIL: model_path=$STARTED_MODEL_PATH"; exit 1; }
[[ "$STARTED_HEALTH_URL" == "http://127.0.0.1:30123/health" ]] || { echo "FAIL: health_url"; exit 1; }

# 2) locate_started_json:取 start-*/started.json 字典序(时间序)最新
mkdir -p "$TMP/root/start-20260101_000000" "$TMP/root/start-20260101_000001"
cp "$TMP/started.json" "$TMP/root/start-20260101_000000/started.json"
cp "$TMP/started.json" "$TMP/root/start-20260101_000001/started.json"
LATEST=$(locate_started_json "$TMP/root")
[[ "$LATEST" == "$TMP/root/start-20260101_000001/started.json" ]] || {
  echo "FAIL: locate=$LATEST"; exit 1; }

# 3) 空目录 -> locate 失败
if locate_started_json "$TMP/empty" >/dev/null 2>&1; then
  echo "FAIL: 空目录应 locate 失败"; exit 1
fi

echo "run_common.test.sh: OK"
