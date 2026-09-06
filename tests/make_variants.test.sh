#!/usr/bin/env bash
# make_variants.test.sh —— make_variants.py 生成器契约测试(纯文件操作,不碰 GPU)
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AUTO_WORK=$(cd -- "$TEST_DIR/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 基线:export 行 + python -m sglang.launch_server(多行反斜杠)
cat >"$TMP/baseline.sh" <<'EOF'
export SGLANG_ENABLE_SPEC_V2=1
unset NCCL_TOPO_FILE
python -m sglang.launch_server \
  --model-path /models/Qwen \
  --tp-size 2 \
  --page-size 16
EOF

cat >"$TMP/spec.json" <<'EOF'
[
  {"label": "baseline", "description": "基线"},
  {"label": "page-64", "description": "page-size 64",
   "args": {"set": [["--page-size", "64"]]}},
  {"label": "cuda-graph-off", "description": "关 cuda graph",
   "args": {"add": ["--cuda-graph-backend-prefill", "disabled"]}},
  {"label": "spec-off", "description": "关 EAGLE",
   "env": {"SGLANG_ENABLE_SPEC_V2": "0"}},
  {"label": "no-topo", "description": "去 NCCL",
   "env_unset": ["NCCL_TOPO_FILE"]}
]
EOF

python3 "$AUTO_WORK/lib/make_variants.py" --baseline "$TMP/baseline.sh" --spec "$TMP/spec.json" --out "$TMP/out"
[[ -f "$TMP/out/.order" ]] || { echo "FAIL: .order 缺失"; exit 1; }
ORDER=$(tr '\n' ',' <"$TMP/out/.order")
[[ "$ORDER" == "baseline,page-64,cuda-graph-off,spec-off,no-topo," ]] || { echo "FAIL: 顺序不符:$ORDER"; exit 1; }

# baseline 不变:仍带 --page-size 16、spec=1、unset NCCL
grep -q -- "--page-size 16" "$TMP/out/baseline/server_command.sh" || { echo "FAIL: baseline page"; exit 1; }
# page-64:page-size 16 被替换为 64,且只出现一次
grep -q -- "--page-size 64" "$TMP/out/page-64/server_command.sh" || { echo "FAIL: page-64 无 64"; exit 1; }
grep -q -- "--page-size 16" "$TMP/out/page-64/server_command.sh" && { echo "FAIL: page-64 残留 16"; exit 1; }
[[ $(grep -c -- "--page-size" "$TMP/out/page-64/server_command.sh") == "1" ]] || { echo "FAIL: page-64 残留旧值"; exit 1; }
# cuda-graph-off:追加标志(选项+取值同行)
grep -q -- "--cuda-graph-backend-prefill disabled" "$TMP/out/cuda-graph-off/server_command.sh" || { echo "FAIL: add 未生效"; exit 1; }
# spec-off:export 覆盖
grep -q "export SGLANG_ENABLE_SPEC_V2=0" "$TMP/out/spec-off/server_command.sh" || { echo "FAIL: env 未覆盖"; exit 1; }
[[ $(grep -c "SGLANG_ENABLE_SPEC_V2" "$TMP/out/spec-off/server_command.sh") == "1" ]] || { echo "FAIL: spec-off 残留旧 export"; exit 1; }
# no-topo:unset 行仍在、原 unset 未重复
grep -q "unset NCCL_TOPO_FILE" "$TMP/out/no-topo/server_command.sh" || { echo "FAIL: unset 缺失"; exit 1; }
# 每目录 spec.json 审计
for l in baseline page-64 cuda-graph-off spec-off no-topo; do
  [[ -f "$TMP/out/$l/spec.json" ]] || { echo "FAIL: $l/spec.json 缺失"; exit 1; }
done

# 非法 label(含 /)应失败
cat >"$TMP/bad.json" <<'EOF'
[{"label": "a/b", "args": {}}]
EOF
if python3 "$AUTO_WORK/lib/make_variants.py" --baseline "$TMP/baseline.sh" --spec "$TMP/bad.json" --out "$TMP/badout" >/dev/null 2>&1; then
  echo "FAIL: 非法 label 应报错"; exit 1
fi

echo "make_variants.test.sh: OK"
