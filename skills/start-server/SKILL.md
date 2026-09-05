---
name: start-server
description: '在服务器上用给定 SGLang 启动命令启动服务:自动等卡、锁卡、选端口、启动、等 /health,汇报 PID/PGID/端口/GPU/日志。Use when: 用户要求启动 SGLang 服务、粘贴 sglang serve 启动命令并要求部署等待就绪,或提到 start-server(未贴命令时默认用 /home/server_command.sh 作为命令源)。'
whenToUse: '用户给出 sglang serve / python -m sglang.launch_server 启动命令(可含 export 行)要求"启动/起服务/部署并等服务就绪";或提到 start-server 但未贴命令(此时以 /home/server_command.sh 为默认命令源,存在才可用)。'
---

# 启动 SGLang 服务(start-server step)

你是执行代理,只做这一件事,完成后即汇报。

## 路径

部署根默认 `/home/auto-work`;若环境变量 `AUTO_WORK`(或 `DSH_BASE_DIR`)已设置,以它为准。运行时数据根默认 `/home/runs`(原 work/ 与 runs/ 合并为一处);若环境变量 `RUNS_DIR` 已设置,以它为准。以下路径据此推导:

- STEP 脚本:`${AUTO_WORK:-/home/auto-work}/steps/start-server.sh`
- 命令解析器:`${AUTO_WORK:-/home/auto-work}/lib/server_command_parser.py`
- 本轮工作目录(兼本轮结果目录):自建 `${RUNS_DIR:-/home/runs}/<ts>`,server_command.sh 与 step 结果都在这里,不再分 work/runs

若 STEP/PARSER 文件缺失,汇报"auto-work 未部署(或缺 lib/server_command_parser.py)",不要继续。

## 步骤

### 1. 写命令文件

启动命令来源,二选一(请求内联 > 默认文件):

- **请求内联**:用户请求里贴了完整启动命令(`export`/`unset` 行 + 一条 `sglang serve` 或 `python -m sglang.launch_server`)时,用用户贴的命令;
- **默认命令文件**:请求没有内联启动命令、但 `/home/server_command.sh` 存在时,以该文件为启动命令源(拷贝到本轮 REQ_WORK 的 server_command.sh,与内联命令同样处理)。

选定来源后,原样规范化并写入本轮工作目录:

```bash
TS=$(date +'%Y%m%d_%H%M%S')
REQ_WORK="${RUNS_DIR:-/home/runs}/${TS}"
mkdir -p "$REQ_WORK"
# 将命令写入 ${REQ_WORK}/server_command.sh,规范化规则:
#   保留 export/unset 与 SGLang 参数;移除 nohup、尾部 &、输出重定向、
#   固定 --port 及值、HIP_VISIBLE_DEVICES;禁止管道/命令替换等无关构造
```

固定 `--port` 处理规则(不要在"删不删"之间纠结,直接删):
- **动作**:命令里出现固定 `--port` 时,连同其值一并删除(`--port 30099`、`--port=30099` 都删),其余参数保留。
- **原因**:端口由 step 自动另选;parser 的 `run` 阶段本就会先移除命令里残留的 `--port`、再在末尾追加所选端口(见 lib/server_command_parser.py 的 `replace_option`,注释"固定端口由自动选择的端口覆盖")。所以删除不会改变最终启动命令——即使漏删也会被自动覆盖,不会按原端口启动;删除只为让 server_command.sh 保持统一的"无端口"规范形态,不是功能必需。

用户若给了 GPU 候选(如 "GPU 2,3,4,5"),转成 `--gpu-allowlist` 传参。

### 2. 校验(失败即停,不启动任何东西)

```bash
python3 "${AUTO_WORK:-/home/auto-work}/lib/server_command_parser.py" metadata "${REQ_WORK}/server_command.sh"
```

### 3. 运行 step(启动服务的唯一途径)

```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/start-server.sh" \
  --server-command "${REQ_WORK}/server_command.sh" \
  --parser "${AUTO_WORK:-/home/auto-work}/lib/server_command_parser.py" \
  --result-root "${REQ_WORK}" \
  [--gpu-allowlist <CSV>]
```

`--result-root` 传本轮 `REQ_WORK`:step 会在此目录下建 `start-<t>/` 写 server.log/started.json/failed.json——本轮命令与结果同在一个目录,不再产生 work/runs 两个目录。

不要直接执行 server_command.sh 内容、不要自己敲 sglang serve、不要绕过 step;step 只做一次尝试,不要重试。

### 4. 汇报

step 打印 `[start-server] STEP_RESULT=<...>`,并在 RUN_DIR 写 `started.json`/`failed.json`(退出码 0=OK, 2=输入错, 3=RETRYABLE, 4=FATAL, 5=TIMEOUT)。

- OK:读 started.json,按下面格式汇报;**服务保持运行,不要停、不要清理**。
- 非 0:读 failed.json(result/stage/error)与日志尾部,汇报失败阶段与原因,不重试。

## 汇报格式

```
结果: <OK|RETRYABLE|FATAL|TIMEOUT|输入错误>
- PID/PGID: <OK 时>
- 端口: <OK 时>
- GPU: <OK 时>
- server 日志: <路径>
- 结果文件: <started.json|failed.json 路径>
- 说明: <一行;失败 = stage + 关键错误>
```

## 纪律

1. 只做这一件事;不改无关文件、不装依赖、不碰 auto-work 以外路径、不杀无关进程。
2. 一次一任务:成功后本任务结束;查状态/停服务由后续任务处理(PGID 已给出)。
3. 请求未内联命令且 `/home/server_command.sh` 不存在(即无任何命令来源)/ 模型路径不存在 / 校验失败 → 按"输入错误"汇报,不要猜、不要补。
