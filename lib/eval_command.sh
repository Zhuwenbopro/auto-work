#!/usr/bin/env bash
set -euo pipefail

# 用法: bash evalscope_more_client.sh [enable_thinking] [datasets]

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'

位置参数:
  $1  enable_thinking  true|false，默认见脚本配置区域
  $2  datasets         逗号分隔，默认见脚本配置区域
  $3+ 预留扩展参数（当前版本忽略）

示例:
  bash evalscope_more_client.sh true humaneval,gsm8k
EOF
    exit 0
fi

if ((BASH_VERSINFO[0] < 4)); then
    echo "错误: 需要 Bash 4+（当前: ${BASH_VERSION}），请用 bash4+/linux 环境运行" >&2
    exit 1
fi

# ==================== 配置区域（按需修改）====================

# auto_eval.sh 会在每轮运行时注入这些变量。
model_path=${MODEL_PATH:?缺少 MODEL_PATH}
ip=${HEALTH_HOST:-127.0.0.1}
port=${PORT:?缺少 PORT}
batch=${EVAL_BATCH:-64}
# limit: None/空=全部；int=前N条；float=前N%
limit=${EVAL_LIMIT:-None}

# 命令行未传参时的默认值
default_enable_thinking=${EVAL_ENABLE_THINKING:-false}
default_datasets_csv=${EVAL_DATASETS:-math_500}

# 扁平扩展配置: key=value,key2=value2
declare -A dataset_configs=(
    [humaneval]="review_timeout=30"
)

# 嵌套 JSON，原样并入 --dataset-args
declare -A dataset_configs_json=(
    [humaneval]='{"filters":{"remove_until":"</think>"}}'
)

# 默认 generation_config 模板；__ENABLE_THINKING__ 由命令行 $1 / 默认值自动替换
generation_config_template='{"timeout":120000,"retries":1,"max_tokens":13312,"temperature":0,"top_p":1,"extra_body":{"chat_template_kwargs":{"enable_thinking":__ENABLE_THINKING__}}}'

# 按数据集覆盖 generation_config（只写差异字段）
declare -A dataset_generation_configs=(
    [humaneval]='{"max_tokens":4096}'
    [math_500]='{"max_tokens":20480}'
)

# ==================== 工具函数（一般无需改动）====================

die() {
    echo "错误: $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*" >&2
}

warn() {
    echo "[WARNING] $*" >&2
}

trim_space() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

json_escape_string() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

require_json() {
    local label="$1"
    local payload="$2"
    if ! python3 -c 'import json,sys; json.loads(sys.argv[1])' "$payload" 2>/dev/null; then
        die "${label} 不是合法 JSON: ${payload}"
    fi
}

merge_generation_config() {
    local base="$1"
    local override="$2"
    local merged
    if ! merged=$(python3 -c '
import json, sys

def deep_merge(base, override):
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base

base = json.loads(sys.argv[1])
override = json.loads(sys.argv[2])
print(json.dumps(deep_merge(base, override), ensure_ascii=False, separators=(",", ":")))
' "$base" "$override" 2>/dev/null); then
        echo "[ERROR] generation_config 合并失败" >&2
        echo "  base: $base" >&2
        echo "  override: $override" >&2
        return 1
    fi
    printf '%s' "$merged"
}

get_generation_config() {
    local override="${dataset_generation_configs[$1]:-}"
    if [[ -z "$override" ]]; then
        printf '%s' "$generation_config"
        return 0
    fi
    merge_generation_config "$generation_config" "$override"
}

parse_config_to_json() {
    local config_str="$1"
    local json_result="{" first=true
    local pair key value formatted_value

    IFS=',' read -ra config_pairs <<< "$config_str"
    for pair in "${config_pairs[@]}"; do
        [[ -z "$pair" ]] && continue
        key=$(trim_space "${pair%%=*}")
        value=$(trim_space "${pair#*=}")
        [[ -z "$key" ]] && { echo "[ERROR] dataset_configs 存在空 key: $pair" >&2; return 1; }
        [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || {
            echo "[ERROR] dataset_configs 非法 key '${key}'（仅允许字母/数字/_）" >&2
            return 1
        }

        if [[ "$value" =~ ^(true|false)$ ]]; then
            formatted_value="$value"
        elif [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            formatted_value="$value"
        else
            formatted_value="\"$(json_escape_string "$value")\""
        fi

        if [[ "$first" == true ]]; then
            json_result="${json_result}\"${key}\": ${formatted_value}"
            first=false
        else
            json_result="${json_result}, \"${key}\": ${formatted_value}"
        fi
    done
    printf '%s' "${json_result}}"
}

strip_json_object_braces() {
    local s
    s=$(trim_space "$1")
    if [[ -z "$s" || "${s:0:1}" != "{" ]]; then
        printf '%s' "$s"
        return 0
    fi

    local i c depth=0 in_str=0 escape=0 end=-1
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        if ((escape)); then
            escape=0
            continue
        fi
        if ((in_str)); then
            if [[ "$c" == "\\" ]]; then
                escape=1
            elif [[ "$c" == '"' ]]; then
                in_str=0
            fi
            continue
        fi
        case "$c" in
            '"') in_str=1 ;;
            '{') depth=$((depth + 1)) ;;
            '}')
                depth=$((depth - 1))
                if ((depth == 0)); then
                    end=$i
                    break
                fi
                ;;
        esac
    done

    if ((end < 0)); then
        printf '%s' "$s"
        return 0
    fi
    local trailing
    trailing=$(trim_space "${s:end+1}")
    if [[ -n "$trailing" ]]; then
        printf '%s' "$s"
        return 0
    fi
    trim_space "${s:1:end-1}"
}

compact_json_fragment() {
    local s="$1"
    local result="" i c in_str=0 escape=0
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        if ((escape)); then
            result+="$c"
            escape=0
            continue
        fi
        if ((in_str)); then
            result+="$c"
            if [[ "$c" == "\\" ]]; then
                escape=1
            elif [[ "$c" == '"' ]]; then
                in_str=0
            fi
            continue
        fi
        if [[ "$c" == '"' ]]; then
            in_str=1
            result+="$c"
            continue
        fi
        [[ "$c" =~ [[:space:]] ]] && continue
        result+="$c"
    done
    printf '%s' "$result"
}

merge_json_field_fragments() {
    local merged="" sep="" part
    for part in "$@"; do
        part=$(trim_space "$part")
        [[ -z "$part" ]] && continue
        part=$(compact_json_fragment "$part")
        [[ -z "$part" ]] && continue
        merged+="${sep}${part}"
        sep=","
    done
    printf '%s' "$merged"
}

build_dataset_arg_entry() {
    local dataset="$1"
    local local_path="$2"
    local config="${3:-}"
    local config_json="${4:-}"
    local escaped_path escaped_dataset extras=()

    escaped_path=$(json_escape_string "$local_path")
    escaped_dataset=$(json_escape_string "$dataset")

    if [[ -n "$config" ]]; then
        local inner
        inner=$(strip_json_object_braces "$(parse_config_to_json "$config")")
        [[ -n "$inner" ]] && extras+=("$inner")
    fi
    if [[ -n "$config_json" ]]; then
        local inner_json
        inner_json=$(strip_json_object_braces "$config_json")
        [[ -n "$inner_json" ]] && extras+=("$inner_json")
    fi

    local fields=()
    [[ -n "$local_path" ]] && fields+=("\"dataset_id\": \"$escaped_path\"")
    fields+=("${extras[@]}")

    if [[ ${#fields[@]} -gt 0 ]]; then
        printf '"%s": {%s}' \
            "$escaped_dataset" "$(merge_json_field_fragments "${fields[@]}")"
    else
        printf '"%s": {}' "$escaped_dataset"
    fi
}

parse_datasets_csv() {
    local csv="$1"
    local raw ds
    local -A seen=()
    local -a raw_list=()

    datasets=()
    IFS=',' read -ra raw_list <<< "$csv"
    for raw in "${raw_list[@]}"; do
        ds=$(trim_space "$raw")
        [[ -z "$ds" ]] && continue
        [[ "$ds" =~ ^[A-Za-z0-9._-]+$ ]] || die "非法数据集名 '${ds}'（仅允许字母/数字/._-）"
        [[ -z "${seen[$ds]:-}" ]] || die "数据集重复: ${ds}"
        seen["$ds"]=1
        datasets+=("$ds")
    done
    [[ ${#datasets[@]} -gt 0 ]] || die "datasets 解析结果为空，原始入参: ${csv}"
}

# ==================== 参数解析 ====================

enable_thinking="${default_enable_thinking}"
datasets_csv="${default_datasets_csv}"

if [[ $# -ge 1 ]]; then
    case "$1" in
        '') ;;
        true|TRUE|True|false|FALSE|False)
            enable_thinking=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            echo "错误: \$1 enable_thinking 只能是 true 或 false，当前值: $1" >&2
            exit 1
            ;;
    esac
fi

[[ $# -ge 2 && -n "${2:-}" ]] && datasets_csv="$2"
[[ $# -ge 3 ]] && warn "\$3 及之后为预留参数，当前版本忽略: ${*:3}"

datasets=()
parse_datasets_csv "$datasets_csv"

# 注入 enable_thinking
generation_config="${generation_config_template//__ENABLE_THINKING__/${enable_thinking}}"

# ==================== 初始化 ====================

model=${model_path##*/}
[[ -e "$model_path" ]] || die "模型路径 ${model_path} 不存在"

bwtype=$(hostname | sed 's/[0-9].*//' | tr -cd 'A-Za-z')
current_time=$(date +"%Y%m%d_%H%M%S")
logpath=${RUN_DIR:-"./${bwtype}_${model}/${current_time}"}
mkdir -p "${logpath}"
log_filename=${EVAL_LOG:-"${logpath}/eval_${current_time}.log"}

limit_args=()
case "${limit:-}" in
    ''|None|NONE|none) ;;
    *) limit_args=(--limit "$limit") ;;
esac

info "enable_thinking=${enable_thinking}, datasets=${datasets[*]}"
require_json "generation_config" "$generation_config"

local_ds=
for local_ds in "${!dataset_generation_configs[@]}"; do
    require_json "dataset_generation_configs[${local_ds}]" "${dataset_generation_configs[$local_ds]}"
done
for local_ds in "${!dataset_configs_json[@]}"; do
    require_json "dataset_configs_json[${local_ds}]" "${dataset_configs_json[$local_ds]}"
done
unset local_ds

# ==================== 主逻辑 ====================

declare -A dataset_arg_map
declare -A dataset_gen_map

for i in "${!datasets[@]}"; do
    dataset="${datasets[$i]}"

    if [[ -n "${dataset_configs[$dataset]:-}" || \
        -n "${dataset_configs_json[$dataset]:-}" ]]; then
        dataset_arg_map["$dataset"]="$(build_dataset_arg_entry \
            "$dataset" "" \
            "${dataset_configs[$dataset]:-}" \
            "${dataset_configs_json[$dataset]:-}")"
    else
        dataset_arg_map["$dataset"]=""
    fi
    dataset_gen_map["$dataset"]="$(get_generation_config "$dataset")"
    require_json "数据集 '${dataset}' 合并后的 generation_config" "${dataset_gen_map[$dataset]}"
done

declare -A gen_to_datasets
for dataset in "${datasets[@]}"; do
    gen_to_datasets["${dataset_gen_map[$dataset]}"]+="${dataset} "
done

cfgs=()
[[ -n "${gen_to_datasets[$generation_config]:-}" ]] && cfgs+=("$generation_config")
for cfg in "${!gen_to_datasets[@]}"; do
    [[ "$cfg" == "$generation_config" ]] && continue
    cfgs+=("$cfg")
done

echo "运行基准测试，日志保存到: ${log_filename}"
for cfg in "${cfgs[@]}"; do
    read -ra group_datasets <<< "${gen_to_datasets[$cfg]}"
    _gd=()
    for d in "${group_datasets[@]}"; do
        [[ -n "$d" ]] && _gd+=("$d")
    done
    group_datasets=("${_gd[@]}")
    unset _gd
    [[ ${#group_datasets[@]} -gt 0 ]] || die "generation_config 分组数据集为空"

    entries=()
    for d in "${group_datasets[@]}"; do
        [[ -n "${dataset_arg_map[$d]:-}" ]] && entries+=("${dataset_arg_map[$d]}")
    done
    datasets_args=""
    if [[ ${#entries[@]} -gt 0 ]]; then
        datasets_args="{$(IFS=,; printf '%s' "${entries[*]}")}"
    fi

    info "评测数据集: ${group_datasets[*]}"
    info "generation-config: ${cfg}"
    [[ -n "$datasets_args" ]] && info "dataset-args: ${datasets_args}"
    [[ -z "$datasets_args" ]] || require_json "dataset-args" "$datasets_args"

    eval_args=(
        evalscope eval
        --model "${model_path}"
        --api-url "http://${ip}:${port}/v1"
        --api-key EMPTY
        --eval-type openai_api
        --eval-batch-size "$batch"
        "${limit_args[@]}"
        --datasets "${group_datasets[@]}"
        --generation-config "${cfg}"
        --stream
        --seed 42
        --work-dir "${logpath}"
    )
    [[ -z "$datasets_args" ]] || eval_args+=(--dataset-args "$datasets_args")
    "${eval_args[@]}"
done

[[ -f "${log_filename}" ]] || die "日志文件 ${log_filename} 未创建"
echo "基准测试完成"
