#!/usr/bin/env python3
"""Parse and run one pasted SGLang server command."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shlex
import sys
import unicodedata
from dataclasses import dataclass


class CommandParseError(ValueError):
    pass


@dataclass
class ParsedCommand:
    argv: list[str]
    exported_env: dict[str, str]
    unset_env: set[str]
    model_path: str
    model_name: str
    tp_size: int
    pp_size: int


SIMPLE_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

VARIABLE_REFERENCE = re.compile(
    r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|"
    r"([A-Za-z_][A-Za-z0-9_]*))"
)

INVISIBLE_NAME_PARTS = (
    "BRAILLE PATTERN BLANK",
    "COMBINING GRAPHEME JOINER",
    "FILLER",
    "INVISIBLE",
    "VARIATION SELECTOR",
    "ZERO WIDTH",
)


def is_invisible_character(char: str) -> bool:
    """判断字符是否属于不可见格式字符。"""

    if unicodedata.category(char) in {"Cf", "Cc"}:
        return True

    unicode_name = unicodedata.name(char, "")

    return any(
        part in unicode_name
        for part in INVISIBLE_NAME_PARTS
    )


def normalize_pasted_text(text: str) -> str:
    """清理从网页、聊天窗口或文档中复制出来的不可见字符。"""

    normalized: list[str] = []

    for char in text:
        # 保留正常的换行和制表符。
        if char in {"\n", "\r", "\t"}:
            normalized.append(char)
            continue

        # 删除零宽字符、BOM、Variation Selector、Filler 等。
        if is_invisible_character(char):
            continue

        # NBSP、全角空格等统一转成普通空格。
        if char.isspace():
            normalized.append(" ")
            continue

        normalized.append(char)

    return "".join(normalized)


def normalize_argv(argv: list[str]) -> list[str]:
    """对 shlex 分词后的参数再次清理。

    这一层专门防止空字符串或只包含不可见字符的参数被传给 SGLang。
    """

    normalized: list[str] = []

    for token in argv:
        cleaned = normalize_pasted_text(token)

        # 丢弃 ""、零宽空格、Braille Blank 等伪空参数。
        if not cleaned.strip():
            continue

        normalized.append(cleaned)

    return normalized


def parse_assignment(
    token: str,
    env: dict[str, str],
    source: Path,
) -> None:
    if "=" not in token:
        raise CommandParseError(
            f"{source}: export 只支持 NAME=value：{token}"
        )

    name, value = token.split("=", 1)

    if not re.fullmatch(
        r"[A-Za-z_][A-Za-z0-9_]*",
        name,
    ):
        raise CommandParseError(
            f"{source}: 非法环境变量名：{name}"
        )

    env[name] = value


def expand_simple_variables(
    value: str,
    env: dict[str, str],
) -> str:
    lookup = dict(os.environ)
    lookup.update(env)

    def replace(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)

        if name not in lookup:
            raise CommandParseError(
                f"命令引用了未定义变量：{name}"
            )

        return lookup[name]

    return VARIABLE_REFERENCE.sub(replace, value)


def get_option(
    argv: list[str],
    name: str,
) -> str | None:
    """读取 --name value 或 --name=value。"""

    value: str | None = None
    index = 0

    while index < len(argv):
        token = argv[index]

        if token == name:
            if index + 1 >= len(argv):
                raise CommandParseError(
                    f"参数 {name} 缺少值"
                )

            value = argv[index + 1]
            index += 2
            continue

        if token.startswith(f"{name}="):
            value = token.split("=", 1)[1]

        index += 1

    return value


def replace_option(
    argv: list[str],
    name: str,
    value: str,
) -> list[str]:
    """删除原参数并添加自动生成的新参数。"""

    result: list[str] = []
    index = 0

    while index < len(argv):
        token = argv[index]

        if token == name:
            if index + 1 >= len(argv):
                raise CommandParseError(
                    f"参数 {name} 缺少值"
                )

            index += 2
            continue

        if token.startswith(f"{name}="):
            index += 1
            continue

        result.append(token)
        index += 1

    result.extend((name, value))

    return result


def parse_positive_int(
    value: str | None,
    name: str,
    default: int,
) -> int:
    if value is None:
        return default

    try:
        parsed = int(value)
    except ValueError as exc:
        raise CommandParseError(
            f"{name} 必须是正整数，实际为：{value}"
        ) from exc

    if parsed <= 0:
        raise CommandParseError(
            f"{name} 必须是正整数，实际为：{value}"
        )

    return parsed


def validate_program(argv: list[str]) -> None:
    """检查是不是支持的 SGLang 启动方式。"""

    if (
        len(argv) >= 2
        and argv[0] == "sglang"
        and argv[1] == "serve"
    ):
        return

    if (
        len(argv) >= 3
        and argv[0] in {"python", "python3"}
        and argv[1:3] == [
            "-m",
            "sglang.launch_server",
        ]
    ):
        return

    raise CommandParseError(
        "只支持 `sglang serve ...` 或 "
        "`python -m sglang.launch_server ...` 启动命令"
    )


def parse_command_file(path: Path) -> ParsedCommand:
    if not path.is_file():
        raise CommandParseError(
            f"服务命令文件不存在：{path}"
        )

    exported_env: dict[str, str] = {}
    unset_env: set[str] = set()
    command_lines: list[str] = []
    command_started = False

    # 先在整份文件层面清理不可见字符。
    pasted_text = normalize_pasted_text(
        path.read_text(encoding="utf-8-sig")
    )

    for line_number, raw_line in enumerate(
        pasted_text.splitlines(),
        start=1,
    ):
        stripped = raw_line.strip()

        if not stripped:
            continue

        if stripped.startswith("#"):
            continue

        if not command_started and stripped in {
            "set -e",
            "set -u",
            "set -eu",
            "set -euo pipefail",
        }:
            continue

        if (
            not command_started
            and stripped.startswith("export ")
        ):
            try:
                export_tokens = shlex.split(
                    stripped,
                    comments=True,
                    posix=True,
                )
            except ValueError as exc:
                raise CommandParseError(
                    f"{path}:{line_number}: "
                    f"export 语法错误：{exc}"
                ) from exc

            for token in export_tokens[1:]:
                parse_assignment(
                    token,
                    exported_env,
                    path,
                )

            continue

        if not command_started and stripped.startswith("unset "):
            try:
                unset_tokens = shlex.split(
                    stripped,
                    comments=True,
                    posix=True,
                )
            except ValueError as exc:
                raise CommandParseError(
                    f"{path}:{line_number}: unset 语法错误：{exc}"
                ) from exc

            if len(unset_tokens) < 2 or any(
                not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token)
                for token in unset_tokens[1:]
            ):
                raise CommandParseError(
                    f"{path}:{line_number}: unset 只支持环境变量名"
                )

            unset_env.update(unset_tokens[1:])
            continue

        if (
            not command_started
            and SIMPLE_ASSIGNMENT.match(stripped)
        ):
            try:
                assignment_tokens = shlex.split(
                    stripped,
                    comments=True,
                    posix=True,
                )
            except ValueError as exc:
                raise CommandParseError(
                    f"{path}:{line_number}: "
                    f"变量赋值语法错误：{exc}"
                ) from exc

            if len(assignment_tokens) != 1:
                raise CommandParseError(
                    f"{path}:{line_number}: "
                    "变量赋值必须单独占一行"
                )

            parse_assignment(
                assignment_tokens[0],
                exported_env,
                path,
            )

            continue

        command_started = True
        command_lines.append(raw_line)

    if not command_lines:
        raise CommandParseError(
            f"{path}: 没有找到 SGLang 启动命令"
        )

    # 所有参数行重新合并成一条命令。
    command_text = "\n".join(command_lines)

    try:
        argv = shlex.split(
            command_text,
            comments=True,
            posix=True,
        )
    except ValueError as exc:
        raise CommandParseError(
            f"{path}: 启动命令语法错误：{exc}"
        ) from exc

    # 对最终参数列表再次清理。
    argv = normalize_argv(argv)

    if not argv:
        raise CommandParseError(
            f"{path}: SGLang 启动命令为空"
        )

    # 后台、重定向和管道由 auto_eval.sh 负责。
    for token in argv:
        if token in {
            "|",
            "||",
            "&&",
            ";",
            "&",
        } or any(
            operator in token
            for operator in (
                ">",
                "<",
                "`",
                "$(",
            )
        ):
            raise CommandParseError(
                "server_command.sh 中不要使用管道、"
                "重定向、后台符号或命令替换；"
                "日志和后台运行由 auto_eval.sh 管理"
            )

    validate_program(argv)

    argv = [
        expand_simple_variables(
            token,
            exported_env,
        )
        for token in argv
    ]

    model_path = get_option(
        argv,
        "--model-path",
    )

    if not model_path:
        raise CommandParseError(
            "SGLang 启动命令缺少 --model-path"
        )

    model_path = model_path.rstrip("/")

    model_name = (
        get_option(
            argv,
            "--served-model-name",
        )
        or Path(model_path).name
    )

    tp_size = parse_positive_int(
        get_option(argv, "--tp-size"),
        "--tp-size",
        1,
    )

    pp_size = parse_positive_int(
        get_option(argv, "--pp-size"),
        "--pp-size",
        1,
    )

    return ParsedCommand(
        argv=argv,
        exported_env=exported_env,
        unset_env=unset_env,
        model_path=model_path,
        model_name=model_name,
        tp_size=tp_size,
        pp_size=pp_size,
    )


def print_metadata(parsed: ParsedCommand) -> None:
    """按照固定的四行输出给 auto_eval.sh。"""

    values = (
        parsed.model_path,
        parsed.model_name,
        str(parsed.tp_size),
        str(parsed.pp_size),
    )

    if any(
        "\n" in value or "\r" in value
        for value in values
    ):
        raise CommandParseError(
            "模型或并行参数中不允许出现换行"
        )

    print("\n".join(values))


def run_command(parsed: ParsedCommand) -> None:
    required_runtime_env = (
        "PORT",
        "HOST",
        "MODEL_NAME",
        "HIP_VISIBLE_DEVICES",
    )

    missing = [
        name
        for name in required_runtime_env
        if not os.environ.get(name)
    ]

    if missing:
        raise CommandParseError(
            "运行服务前缺少自动调度变量："
            + ", ".join(missing)
        )

    argv = parsed.argv

    # 固定端口由自动选择的端口覆盖。
    argv = replace_option(
        argv,
        "--port",
        os.environ["PORT"],
    )

    # 服务监听地址由 config.env 控制。
    argv = replace_option(
        argv,
        "--host",
        os.environ["HOST"],
    )

    # 没有显式模型名时使用自动提取的模型名。
    argv = replace_option(
        argv,
        "--served-model-name",
        os.environ["MODEL_NAME"],
    )

    # 在 exec 前做最后一次参数清理。
    argv = normalize_argv(argv)

    child_env = dict(os.environ)

    for name, value in parsed.exported_env.items():
        # 固定卡号不生效，使用 auto_eval.sh 自动选择的卡。
        if name == "HIP_VISIBLE_DEVICES":
            continue

        child_env[name] = expand_simple_variables(
            value,
            parsed.exported_env,
        )

    for name in parsed.unset_env:
        child_env.pop(name, None)

    child_env["HIP_VISIBLE_DEVICES"] = (
        os.environ["HIP_VISIBLE_DEVICES"]
    )

    try:
        os.execvpe(
            argv[0],
            argv,
            child_env,
        )
    except FileNotFoundError as exc:
        raise CommandParseError(
            f"找不到服务启动程序：{argv[0]}"
        ) from exc


def main() -> int:
    argument_parser = argparse.ArgumentParser()

    argument_parser.add_argument(
        "action",
        choices=(
            "metadata",
            "run",
        ),
    )

    argument_parser.add_argument(
        "command_file",
        type=Path,
    )

    args = argument_parser.parse_args()

    try:
        parsed = parse_command_file(
            args.command_file
        )

        if args.action == "metadata":
            print_metadata(parsed)
        else:
            run_command(parsed)

    except CommandParseError as exc:
        print(
            f"错误：{exc}",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())