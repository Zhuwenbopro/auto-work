#!/usr/bin/env bash
# ============================================================================
# run_common.sh —— run-* workload step 的共享库(被 source,不单独执行)
#
# 提供:读取 started.json / 定位 --server-root 下最新 started.json /
#   健康探测 / 进程组终止(TERM->宽限->KILL) / JSON 写入 / 数值校验。
# 约定:调用方先 `set -Eeuo pipefail`,再 source 本文件。
# ============================================================================

log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*"; }
die() { log "错误:$*"; exit 2; }

is_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# SELF_PGID 懒初始化(terminate_process_group 的自杀保护)
ensure_self_pgid() {
  [[ -n "${SELF_PGID:-}" ]] || SELF_PGID=$(python3 -c 'import os; print(os.getpgrp())')
}

# read_started_json <file>:把 started.json 关键字段读入全局 STARTED_* 变量
# 字段:pid pgid port model_name model_path health_url server_log run_dir
read_started_json() {
  local file=$1 fields
  fields=$(python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    obj = json.load(f)
keys = ("pid", "pgid", "port", "model_name", "model_path", "health_url", "server_log", "run_dir")
print("\t".join(str(obj.get(k, "")) for k in keys))
PY
  ) || die "started.json 无法解析:$file"
  IFS=$'\t' read -r STARTED_PID STARTED_PGID STARTED_PORT \
    STARTED_MODEL_NAME STARTED_MODEL_PATH STARTED_HEALTH_URL \
    STARTED_SERVER_LOG STARTED_RUN_DIR <<<"$fields"
}

# locate_started_json <server-root>:取 <root>/start-*/started.json 中最新的一个
# (按路径字典序取最后一个;start-<ts> 命名保证时间序)。
locate_started_json() {
  local root=$1 newest=""
  [[ -d "$root" ]] || return 1
  while IFS= read -r -d '' f; do
    newest=$f
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name started.json -print0 2>/dev/null | sort -z)
  [[ -n "$newest" ]] && { printf '%s' "$newest"; return 0; }
  return 1
}

# health_ok <url>:curl -fsS 通过返回 0(--max-time 10 防止探测挂起)
health_ok() {
  curl -fsS --max-time 10 "$1" >/dev/null 2>&1
}

# get_process_group <pid>
get_process_group() {
  local pid=$1 pgid
  pgid=$(python3 - "$pid" 2>/dev/null <<'PY' || true
import os
import sys
print(os.getpgid(int(sys.argv[1])))
PY
  )
  printf '%s\n' "${pgid:-$pid}"
}

# target_live <target>:target 形如 "-PGID"(进程组)或 "PID"。
# 判定目标是否仍有"非僵尸"存活成员:kill -0 对僵尸也返回真,必须查 ps stat
# (僵尸首字符为 Z,视为已死)。
target_live() {
  local t=$1 line
  if [[ "$t" == -* ]]; then
    while IFS= read -r line; do
      [[ -n "${line:0:1}" && "${line:0:1}" != Z ]] && return 0
    done < <(ps -g "${t#-}" -o stat= 2>/dev/null || true)
    return 1
  fi
  kill -0 "$t" 2>/dev/null || return 1
  line=$(ps -o stat= -p "$t" 2>/dev/null | tr -d ' ')
  [[ -n "$line" && "${line:0:1}" != Z ]]
}

# terminate_process_group <name> <pid> <pgid> <timeout_s>:
# TERM -> 每 1s 轮询 -> 超时 KILL -> wait。pgid 非数字或 == 自身时退化为单 PID。
terminate_process_group() {
  local name=$1 pid=$2 pgid=$3 timeout_s=$4
  local deadline target
  [[ -n "$pid" ]] || return 0
  ensure_self_pgid
  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" != "$SELF_PGID" ]]; then
    target="-$pgid"
  else
    target="$pid"
  fi
  if target_live "$target"; then
    log "停止${name}:PID=${pid},PGID=${pgid}"
    kill -TERM -- "$target" 2>/dev/null || true
    deadline=$((SECONDS + timeout_s))
    while target_live "$target" && ((SECONDS < deadline)); do
      sleep 1
    done
    if target_live "$target"; then
      log "${name}未在 ${timeout_s}s 内退出,发送 KILL"
      kill -KILL -- "$target" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

# write_json_file <file> <k1> <v1> <k2> <v2> ...:JSON 写入(numeric_keys 转 int)
write_json_file() {
  local file=$1
  shift
  python3 - "$file" "$@" <<'PY'
import json
import sys
file = sys.argv[1]
pairs = sys.argv[2:]
obj = {}
numeric_keys = {"pid", "pgid", "port", "elapsed_s", "exit_code"}
for i in range(0, len(pairs), 2):
    key = pairs[i]
    value = pairs[i + 1]
    if key in numeric_keys:
        try:
            value = int(value)
        except ValueError:
            pass
    obj[key] = value
with open(file, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY
}
