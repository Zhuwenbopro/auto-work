#!/usr/bin/env bash
# ============================================================================
# adapt-attempt.sh —— step:适配循环的"单次启动尝试"(确定性证据采集)
#
# 职责:把命令源拷贝进本轮目录 → 调 start-server step 做一次真实启动 → 把结果压成
#      机器可读 attempt.json(ok/stage/error/signature/首个 sglang 帧文件:行/
#      started_json/failed_json/server_log),供 adapt-start 用精确字段比较判断推进。
#
# 布局(与 start-server 对齐,运行时数据根 RUNS_DIR,默认 /home/runs):
#   ${RUN_DIR}             本轮目录 = ${RUNS_DIR}/adapt-<ts>/iter-<NNN>
#     server_command.sh    命令源拷贝(与 step 结果同目录)
#     step.out             start-server 调用留档
#     start-<ts>/…         start-server step 产物(started.json / failed.json / server.log)
#     attempt.json         本轮结构化证据(本脚本产出)
#
# 用法:
#   bash adapt-attempt.sh --run-dir DIR --server-command PATH \
#       [--parser PATH] [--src-dir DIR]
# 输出:${RUN_DIR}/attempt.json;stdout 打一行 [adapt-attempt] ok=... signature=...
# 退出码:0 = 本次尝试已记录(成功与否看 attempt.json.ok);2 = 用法错误
# ============================================================================
set -Eeuo pipefail

AUTO_WORK="${AUTO_WORK:-/home/auto-work}"
RUN_DIR=""
SERVER_COMMAND=""
PARSER="${PARSER:-${AUTO_WORK}/lib/server_command_parser.py}"
SRC_DIR="/home/sglang-das"
STEP="${STEP_START_SERVER:-${AUTO_WORK}/steps/start-server.sh}"

while (($#)); do
  case "$1" in
    --run-dir)        RUN_DIR=$2; shift 2 ;;
    --server-command) SERVER_COMMAND=$2; shift 2 ;;
    --parser)         PARSER=$2; shift 2 ;;
    --src-dir)        SRC_DIR=$2; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数:$1" >&2; exit 2 ;;
  esac
done

[ -n "$RUN_DIR" ] && [ -n "$SERVER_COMMAND" ] || { echo "缺 --run-dir/--server-command" >&2; exit 2; }
[ -f "$SERVER_COMMAND" ] || { echo "server 命令文件不存在:$SERVER_COMMAND" >&2; exit 2; }
[ -f "$STEP" ] || { echo "start-server step 不存在:$STEP" >&2; exit 2; }
[ -f "$PARSER" ] || { echo "parser 不存在:$PARSER" >&2; exit 2; }

mkdir -p "$RUN_DIR"
cp "$SERVER_COMMAND" "$RUN_DIR/server_command.sh"

# 一次真实启动:命令与 step 结果同在本轮目录(与 start-server 任务对齐)
set +e
bash "$STEP" \
  --server-command "$RUN_DIR/server_command.sh" \
  --parser "$PARSER" \
  --result-root "$RUN_DIR" >"$RUN_DIR/step.out" 2>&1
CODE=$?
set -e

# 定位 step 产物(最新一个 start-<ts>/)
START_DIR=""
for d in "$RUN_DIR"/start-*/; do
  [ -d "$d" ] && START_DIR=$d
done

FAILED_JSON=""
STARTED_JSON=""
SERVER_LOG=""
if [ -n "$START_DIR" ]; then
  [ -f "$START_DIR/failed.json" ] && FAILED_JSON=$START_DIR/failed.json
  [ -f "$START_DIR/started.json" ] && STARTED_JSON=$START_DIR/started.json
  [ -f "$START_DIR/server.log" ] && SERVER_LOG=$START_DIR/server.log
fi

python3 - "$RUN_DIR/attempt.json" "$CODE" "$FAILED_JSON" "$STARTED_JSON" "$SERVER_LOG" "$SRC_DIR" "$RUN_DIR" <<'PY'
import json, os, re, sys

out, code, failed_json, started_json, server_log, src, run_dir = sys.argv[1:]

ok = False
stage, error = "", ""
if failed_json and os.path.exists(failed_json):
    try:
        fj = json.load(open(failed_json))
    except Exception:
        fj = {}
    ok = fj.get("result") == "ok"
    stage = fj.get("stage", "")
    error = fj.get("error", "")
elif started_json and os.path.exists(started_json):
    ok = True

sig, sgl_file, sgl_line = "", "", ""
if not ok and server_log and os.path.exists(server_log):
    try:
        text = open(server_log, encoding="utf-8", errors="replace").read()
    except Exception:
        text = ""
    blocks = text.split("Traceback (most recent call last):")
    if len(blocks) > 1:
        block = blocks[-1]
        frames = re.findall(r'File "([^"]+)", line (\d+)', block)
        sgl = [(f, int(l)) for f, l in frames if src in f]
        if sgl:
            # 取最深的 sglang 帧(离第三方报错最近的自研调用点)= 真正要改的位置
            sgl_file, sgl_line = sgl[-1]
        excs = re.findall(r'\n([A-Za-z_][A-Za-z0-9_.]*): ', block)
        exc = excs[-1].strip() if excs else ""
        if sgl_file:
            sig = f"{exc}: {sgl_file}:{sgl_line}"

data = {
    "ok": bool(ok),
    "code": int(code),
    "stage": stage,
    "error": error,
    "signature": sig,
    "sglang_file": sgl_file,
    "sglang_line": sgl_line,
    "server_log": server_log,
    "failed_json": failed_json,
    "started_json": started_json,
    "run_dir": run_dir,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

SIG=$(python3 -c "import json;print(json.load(open('$RUN_DIR/attempt.json'))['signature'])" 2>/dev/null || true)
OK=$(python3 -c "import json;print(json.load(open('$RUN_DIR/attempt.json'))['ok'])" 2>/dev/null || false)
echo "[adapt-attempt] ok=$OK signature=$SIG"
exit 0
