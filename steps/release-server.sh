#!/usr/bin/env bash
# ============================================================================
# release-server.sh —— step: 按 started.json 停止服务并复核资源释放(单一职责)
#
# 职责:给定一份 start-server.sh 产出的 started.json(pid/pgid/gpus_csv),
#   停掉对应服务进程组(TERM -> 宽限 -> KILL,沿用 start-server 清理语义),
#   并复核 gpus_csv 内各卡当前显存/HCU 状态,结果写 release.json。
#   本 step 幂等:目标进程已不在 -> result=already_gone,仍执行 GPU 复核。
#
# 结果码:
#   0  OK       服务已停(或本就已停),GPU 状态已复核,写 release.json
#   2  输入/用法错误(started.json 缺失/损坏/字段非法,未动任何进程)
#   4  FATAL    进程存在但 TERM/KILL 后仍存活(极端),或复核失败
#
# 用法:
#   bash release-server.sh --started-json PATH [选项]
#   选项:
#     --started-json PATH  必填。start-server.sh 产出的 started.json
#     --config PATH        可选 config.env(仅取 SHUTDOWN_TIMEOUT / GPU 阈值)
#     -h, --help
#
# 环境:依赖 python3 rocm-smi;由 config/环境控制:
#   SHUTDOWN_TIMEOUT(=15s TERM 宽限)/GPU_VRAM_MAX_PERCENT(=5)/GPU_HCU_MAX_PERCENT(=0)
#
# 产物(与 started.json 同目录):release.json
#   { "result": "released|already_gone|failed",
#     "pid": .., "pgid": .., "gpus_csv": "0,2",
#     "gpus_state": [ {"gpu": 0, "vram_pct": 0, "hcu_pct": 0, "idle": true}, ... ],
#     "server_log": "..", "run_dir": "..", "elapsed_s": .. }
#
# 注意:GPU/端口 flock 由服务进程组持有并随进程退出自动释放;本 step 不删锁文件。
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ---------------- 参数解析 ----------------
STARTED_JSON=""
CONFIG_FILE=""

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2
}

while (($#)); do
  case "$1" in
    --started-json)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--started-json 需要路径" >&2; exit 2; }
      STARTED_JSON=$2; shift 2 ;;
    --config)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--config 需要路径" >&2; exit 2; }
      CONFIG_FILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误:未知参数:$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$STARTED_JSON" ]] || { echo "错误:必须提供 --started-json" >&2; exit 2; }
[[ -f "$STARTED_JSON" ]] || { echo "错误:started.json 不存在:$STARTED_JSON" >&2; exit 2; }

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "错误:配置文件不存在:$CONFIG_FILE" >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

: "${SHUTDOWN_TIMEOUT:=15}"
: "${GPU_VRAM_MAX_PERCENT:=5}"
: "${GPU_HCU_MAX_PERCENT:=0}"

for cmd in python3 rocm-smi; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "错误:找不到命令:$cmd" >&2; exit 2; }
done

log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*"; }
die() { log "错误:$*"; exit 2; }

# ---------------- 读取 started.json ----------------
# 输出(制表符分隔):pid pgid gpus_csv server_log run_dir
if ! STARTED_FIELDS=$(python3 - "$STARTED_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    obj = json.load(f)
print("\t".join(str(obj.get(k, "")) for k in ("pid", "pgid", "gpus_csv", "server_log", "run_dir")))
PY
); then
  die "started.json 无法解析:$STARTED_JSON"
fi
IFS=$'\t' read -r SERVER_PID SERVER_PGID GPUS_CSV SERVER_LOG RUN_DIR <<<"$STARTED_FIELDS"

[[ "$SERVER_PID" =~ ^[0-9]+$ && "$SERVER_PID" -gt 0 ]] || die "started.json 缺少合法 pid"

# 输出目录:优先 started.json 所在目录(与 start-server 产物同处,审计自含)
RELEASE_DIR=$(cd -- "$(dirname -- "$STARTED_JSON")" && pwd)
OUT_FILE="${RELEASE_DIR}/release.json"
START_SEC=$SECONDS
SELF_PGID=$(python3 -c 'import os; print(os.getpgrp())')
RESULT="failed"
TARGET=""

# ---------------- 停服(沿用 start-server 清理语义) ----------------
if [[ "$SERVER_PGID" =~ ^[0-9]+$ && "$SERVER_PGID" != "$SELF_PGID" ]]; then
  TARGET="-$SERVER_PGID"
else
  TARGET="$SERVER_PID"
fi

if kill -0 -- "$TARGET" 2>/dev/null; then
  log "停止 SGLang Server:PID=${SERVER_PID},PGID=${SERVER_PGID}"
  kill -TERM -- "$TARGET" 2>/dev/null || true
  deadline=$((SECONDS + SHUTDOWN_TIMEOUT))
  while kill -0 -- "$TARGET" 2>/dev/null && ((SECONDS < deadline)); do
    sleep 1
  done
  if kill -0 -- "$TARGET" 2>/dev/null; then
    log "SGLang Server 未在 ${SHUTDOWN_TIMEOUT}s 内退出,发送 KILL"
    kill -KILL -- "$TARGET" 2>/dev/null || true
    sleep 1
  fi
  if kill -0 -- "$TARGET" 2>/dev/null; then
    log "错误:SGLang Server 在 TERM+KILL 后仍存活(pid=${SERVER_PID})"
    RESULT="failed"
  else
    RESULT="released"
    log "SGLang Server 已停止"
  fi
else
  RESULT="already_gone"
  log "SGLang Server 已不在运行(pid=${SERVER_PID}),跳过停服"
fi

# ---------------- GPU 复核 ----------------
# 采集 gpus_csv 各卡当前状态,并对照阈值给出 idle 判定(仅供汇报;锁随进程释放)
query_gpu_state() {
  rocm-smi 2>/dev/null | awk \
    -v max_vram="$GPU_VRAM_MAX_PERCENT" \
    -v max_hcu="$GPU_HCU_MAX_PERCENT" '
      $1 ~ /^[0-9]+$/ {
        gpu=$1
        vram=$6
        hcu=$7
        gsub(/%/, "", vram)
        gsub(/%/, "", hcu)
        idle = ((vram + 0) < max_vram && (hcu + 0) <= max_hcu) ? "true" : "false"
        printf "%s %s %s %s\n", gpu, vram, hcu, idle
      }
    '
}

GPU_STATE_JSON="[]"
if [[ -n "$GPUS_CSV" ]]; then
  if state_output=$(query_gpu_state); then
    GPU_STATE_JSON=$(python3 - "$state_output" <<'PY'
import json
import sys
lines = [ln.split() for ln in sys.argv[1].splitlines() if ln.split()]
rows = []
for gpu, vram, hcu, idle in lines:
    rows.append({
        "gpu": int(gpu),
        "vram_pct": float(vram),
        "hcu_pct": float(hcu),
        "idle": idle == "true",
    })
print(json.dumps(rows, ensure_ascii=False))
PY
    )
  else
    log "rocm-smi 复核失败,仅记录已停服结果"
    GPU_STATE_JSON="[]"
  fi
fi

elapsed=$((SECONDS - START_SEC))
python3 - "$OUT_FILE" "$RESULT" "$SERVER_PID" "$SERVER_PGID" "$GPUS_CSV" "$GPU_STATE_JSON" "$SERVER_LOG" "$RUN_DIR" "$elapsed" <<'PY'
import json
import sys
out, result, pid, pgid, gpus_csv, state_json, server_log, run_dir, elapsed = sys.argv[1:]
obj = {
    "result": result,
    "pid": int(pid) if pid.isdigit() else pid,
    "pgid": int(pgid) if pgid.isdigit() else pgid,
    "gpus_csv": gpus_csv,
    "gpus_state": json.loads(state_json),
    "server_log": server_log,
    "run_dir": run_dir,
    "elapsed_s": int(elapsed),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY

if [[ "$RESULT" == "failed" ]]; then
  echo "[release-server] STEP_RESULT=failed pid=${SERVER_PID} pgid=${SERVER_PGID} release_json=$OUT_FILE"
  exit 4
fi
echo "[release-server] STEP_RESULT=${RESULT} pid=${SERVER_PID} pgid=${SERVER_PGID} release_json=$OUT_FILE"
exit 0
