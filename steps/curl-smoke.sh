#!/usr/bin/env bash
# ============================================================================
# curl-smoke.sh —— step:启动成功后的一次确定性 curl 冒烟 + 乱码判定
#
# 职责:从 started.json 读 port/model,发一次最小 chat 请求,用确定性规则给出
#       verdict(http 错 / json 错 / 空内容 / 含 U+FFFD / 正常),避免 LLM 主观判断。
#
# 用法:
#   bash curl-smoke.sh --started-json PATH [--max-tokens N]
# 输出:${STARTED_JSON 同目录}/smoke.json;stdout 打一行 [smoke] verdict=...
# 退出码:0 = 请求已执行并判定(verdict 见 smoke.json);2 = 用法错误
# ============================================================================
set -Eeuo pipefail

STARTED_JSON=""
MAX_TOKENS=32

while (($#)); do
  case "$1" in
    --started-json) STARTED_JSON=$2; shift 2 ;;
    --max-tokens)   MAX_TOKENS=$2; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数:$1" >&2; exit 2 ;;
  esac
done

[ -f "$STARTED_JSON" ] || { echo "started.json 不存在:$STARTED_JSON" >&2; exit 2; }
[[ "$MAX_TOKENS" =~ ^[1-9][0-9]*$ ]] || { echo "max-tokens 需为正整数" >&2; exit 2; }

# 读 port/model_name 并生成请求体
REQ_FILE="$(dirname "$STARTED_JSON")/smoke_request.json"
python3 - "$STARTED_JSON" "$REQ_FILE" "$MAX_TOKENS" <<'PY'
import json, sys
started, req, max_tokens = sys.argv[1:4]
d = json.load(open(started))
port = d.get("port")
model = d.get("model_name") or d.get("model") or "default"
if not port:
    raise SystemExit("started.json 缺少 port")
body = {
    "model": model,
    "messages": [{"role": "user", "content": "你好,请只回复 OK 两个字母"}],
    "max_tokens": int(max_tokens),
}
json.dump(body, open(req, "w"), ensure_ascii=False)
print(port)
PY
PORT=$(python3 -c "import json;print(json.load(open('$STARTED_JSON'))['port'])")
MODEL=$(python3 -c "import json;print(json.load(open('$STARTED_JSON')).get('model_name') or json.load(open('$STARTED_JSON')).get('model') or '')")

RESP_FILE="$(dirname "$STARTED_JSON")/smoke_response.json"
HTTP_CODE=$(curl -sS -m 60 -o "$RESP_FILE" -w '%{http_code}' \
  "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' --data "@$REQ_FILE" 2>/dev/null) || HTTP_CODE=000

python3 - "$(dirname "$STARTED_JSON")/smoke.json" "$HTTP_CODE" "$RESP_FILE" <<'PY'
import json, os, sys

out, http, resp_file = sys.argv[1:4]
verdict, reason, content = "error", "", ""

if http != "200":
    verdict, reason = "http_error", f"HTTP={http}"
else:
    try:
        data = json.load(open(resp_file))
        content = data["choices"][0]["message"]["content"]
    except Exception as e:
        verdict, reason = "json_error", f"响应解析失败:{e}"
    else:
        if content is None or str(content).strip() == "":
            verdict, reason = "empty", "content 为空"
        elif "\ufffd" in content:
            verdict, reason = "garbled", "输出含 U+FFFD 替换字符"
        else:
            verdict, reason = "ok", "输出可解析且无替换字符"

with open(out, "w", encoding="utf-8") as f:
    json.dump({
        "http": http,
        "verdict": verdict,
        "reason": reason,
        "content": content[:200],
        "model": os.environ.get("SMOKE_MODEL", ""),
    }, f, ensure_ascii=False, indent=2)
PY

echo "[smoke] http=$HTTP_CODE verdict=$(python3 -c "import json;print(json.load(open('$(dirname "$STARTED_JSON")/smoke.json'))['verdict'])" 2>/dev/null || echo error)"
exit 0
