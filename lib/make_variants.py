#!/usr/bin/env python3
"""make_variants.py —— cmp-eval / cmp-bench 的确定性变体命令生成器。

输入基线 server_command.sh + variants spec(JSON),输出每个变体一份
规范化、可交给 start-server 的 server_command.sh,用于"单一变量对比"实验。

spec 是 JSON 数组,每项(顺序即执行顺序):
{
  "label": "baseline",              # 必填,唯一,^[A-Za-z0-9._-]+$,不含 /
  "description": "baseline",        # 可选,进汇报
  "env": {"NAME": "value", ...},    # 可选:export/覆盖这些环境变量
  "env_unset": ["NAME", ...],       # 可选:unset 这些环境变量
  "args": {                          # 可选:sglang serve 参数变更
    "add":    ["--flag", "v", ...],       # 追加原样参数(布尔开关等)
    "set":    [["--page-size", "64"], ...],  # 替换选项值(含覆盖基线同名)
    "remove": ["--page-size", ...]         # 删除选项(若带值且值不以 - 开头一并删)
  }
}

对基线的处理:
- export/unset 行保留并按 env/env_unset 增删(重写为统一形态);
- 命令只接受 `sglang serve ...` 或 `python[-3] -m sglang.launch_server ...`
  (含反斜杠续行),参数按空白分词(shlex);--port/HIP_VISIBLE_DEVICES 等
  交 start-server/parser 处理,这里不负责剥离;
- 输出每份文件:export/unset 行 + 命令(每个参数一行、反斜杠续行),便于 diff 与审计。

用法:
  python3 make_variants.py --baseline server_command.sh --spec variants.json --out DIR
退出码:0 成功;2 输入/校验错误(不产出)。
"""

import argparse
import json
import re
import shlex
import sys
from pathlib import Path

LABEL_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def die(msg: str) -> None:
    print(f"错误:{msg}", file=sys.stderr)
    raise SystemExit(2)


def parse_baseline(path: Path):
    """返回 (env_lines, exec_prefix, args)。"""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"读取基线失败:{exc}")
    env_lines: list[str] = []
    cmd_parts: list[str] = []
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("export ") or stripped.startswith("unset "):
            env_lines.append(stripped)
        else:
            cmd_parts.append(stripped.rstrip("\\").strip())
    if not cmd_parts:
        die("基线命令为空(没有找到 serve 命令行)")
    tokens = shlex.split(" ".join(cmd_parts))
    # 定位启动形态
    if len(tokens) >= 3 and tokens[0] in ("python", "python3") and tokens[1] == "-m" and tokens[2] == "sglang.launch_server":
        exec_prefix = [tokens[0], "-m", "sglang.launch_server"]
        args = tokens[3:]
    elif len(tokens) >= 2 and tokens[0] == "sglang" and tokens[1] == "serve":
        exec_prefix = ["sglang", "serve"]
        args = tokens[2:]
    else:
        die("基线命令必须形如 `sglang serve ...` 或 `python -m sglang.launch_server ...`")
    return env_lines, exec_prefix, args


def drop_option(args: list[str], opt: str) -> list[str]:
    """删除某选项;若其后紧跟一个不以 - 开头的值则一并删除(启发式)。"""
    out: list[str] = []
    i = 0
    n = len(args)
    while i < n:
        if args[i] == opt:
            if i + 1 < n and not args[i + 1].startswith("-"):
                i += 2
            else:
                i += 1
            continue
        out.append(args[i])
        i += 1
    return out


def apply_env(env_lines: list[str], env: dict, env_unset: list[str]) -> list[str]:
    """按 env/env_unset 重建 export/unset 行(覆盖/删除同名项)。"""
    kept: list[str] = []
    for line in env_lines:
        name = line.split()[1].split("=", 1)[0] if line.startswith("export ") else line.split()[1]
        if name in env or name in env_unset:
            continue
        kept.append(line)
    for name in env_unset:
        kept.append(f"unset {name}")
    for name, value in env.items():
        kept.append(f"export {name}={shlex.quote(str(value))}")
    return kept


def render(exec_prefix: list[str], args: list[str], env_lines: list[str]) -> str:
    """输出:export/unset 行 + serve 命令。选项与其值同在一行(便于 diff/审计)。"""
    lines: list[str] = list(env_lines)
    if lines:
        lines.append("")
    head = " ".join(exec_prefix)
    body: list[str] = []
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]
        if tok.startswith("-") and i + 1 < n and not args[i + 1].startswith("-"):
            body.append(f"{tok} {args[i + 1]}")
            i += 2
        else:
            body.append(tok)
            i += 1
    if not body:
        lines.append(head)
    else:
        lines.append(head + " \\")
        last = len(body) - 1
        for idx, part in enumerate(body):
            lines.append("    " + part + (" \\" if idx < last else ""))
    lines.append("")
    return "\n".join(lines)


def apply_args(base_args: list[str], ops: dict) -> list[str]:
    out = list(base_args)
    for opt in ops.get("remove", []):
        out = drop_option(out, opt)
    for opt, val in ops.get("set", []):
        out = drop_option(out, opt)
        out.extend([opt, str(val)])
    out.extend(ops.get("add", []))
    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--baseline", required=True, type=Path)
    p.add_argument("--spec", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    args = p.parse_args()

    if not args.baseline.is_file():
        die(f"基线命令文件不存在:{args.baseline}")
    try:
        spec = json.loads(args.spec.read_text(encoding="utf-8"))
    except OSError as exc:
        die(f"读取 spec 失败:{exc}")
    except json.JSONDecodeError as exc:
        die(f"spec 不是合法 JSON:{exc}")
    if not isinstance(spec, list) or not spec:
        die("spec 必须是非空 JSON 数组")

    labels: set[str] = set()
    ordered: list[str] = []
    base_env, exec_prefix, base_args = parse_baseline(args.baseline)

    args.out.mkdir(parents=True, exist_ok=True)
    for entry in spec:
        if not isinstance(entry, dict):
            die("spec 每项必须是对象")
        label = entry.get("label")
        if not isinstance(label, str) or not LABEL_RE.match(label):
            die(f"label 非法(仅允许字母/数字/._-,不含 /):{label!r}")
        if label in labels:
            die(f"label 重复:{label}")
        labels.add(label)
        ordered.append(label)

        vdir = args.out / label
        vdir.mkdir(parents=True, exist_ok=True)
        env_lines = apply_env(list(base_env), entry.get("env", {}), entry.get("env_unset", []))
        variant_args = apply_args(list(base_args), entry.get("args", {})) if isinstance(entry.get("args"), dict) else list(base_args)
        content = render(exec_prefix, variant_args, env_lines)
        (vdir / "server_command.sh").write_text(content, encoding="utf-8")
        audit = {
            "label": label,
            "description": entry.get("description", ""),
            "env": entry.get("env", {}),
            "env_unset": entry.get("env_unset", []),
            "args": entry.get("args", {}),
        }
        (vdir / "spec.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # 顺序清单 + spec 审计副本,供 cmp-sweep 与汇报使用
    (args.out / ".order").write_text("\n".join(ordered) + "\n", encoding="utf-8")
    (args.out / "spec.json").write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已生成 {len(ordered)} 个变体到 {args.out}:{','.join(ordered)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
