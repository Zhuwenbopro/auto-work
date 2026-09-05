# Headless 任务:启动 SGLang 服务(start-server)

> 用法:调用方(人/驱动器)的整条消息 = 本文件内容 + "用户请求" + "本轮参数"。
> **路径一律以消息末尾"本轮参数"为准**(AUTO_WORK/REQ_WORK/RESULT_ROOT/STEP/PARSER);
> 若没有给"本轮参数"(如直接用 dsh 调用),代码根默认 /home/auto-work、运行时数据根默认 /home/runs,可用环境变量 AUTO_WORK/DSH_BASE_DIR/RUNS_DIR 覆盖。
> 你是容器内的一次性执行代理,只做下面这一件事,做完即汇报,不要多做。

## 你要做的事

### 1. 提取并规范化启动命令

命令来源,二选一(请求内联 > 默认文件):

- **请求内联**:用户请求里贴了完整 SGLang 启动命令(`export`/`unset` 行 + 一条 `sglang serve` 或 `python -m sglang.launch_server`)时,用用户贴的;
- **默认命令文件**:请求未内联启动命令、但 `/home/server_command.sh` 存在时,以该文件为启动命令源(拷贝到 REQ_WORK 的 server_command.sh,与内联命令同样处理)。

选定来源后原样写入 `${REQ_WORK}/server_command.sh`(REQ_WORK 取"本轮参数",缺省 `${RUNS_DIR:-/home/runs}/<时间戳>`;RESULT_ROOT 缺省 = 本轮 REQ_WORK,命令与 step 结果同在一个目录,不再分 work/runs),并做规范化:

- 保留 `export`、`unset` 与 SGLang 参数;
- **移除**:`nohup`、尾部 `&`、输出重定向(如 `>file 2>&1`)、`--port` 及其值、`HIP_VISIBLE_DEVICES` 的赋值/export;
- **禁止**:管道、命令替换、`;`/`&&` 等与启动服务无关的构造;
- 不要自行添加端口/卡号替代值(由 step 自动分配)。

**`--port` 看到就删,不要在"删不删"之间纠结**:端口由 step 自动另选;parser 的 `run` 阶段会先把命令里残留的 `--port` 全部移除、再在末尾追加所选端口,所以删不删最终都会以所选端口启动(漏删也会被自动覆盖,不会按原端口监听)。删除只是为了文件形态统一,不是功能必需。

如果用户请求里同时给了 GPU 候选(例如"GPU 2,3,4,5"或"--gpu-allowlist 2,3,4,5"),解析成 CSV 备用。

### 2. 校验(任一失败立即停下汇报,不启动任何东西)

```bash
python3 "${PARSER}" metadata "${REQ_WORK}/server_command.sh"
```

退出码非 0 = 校验失败:原样汇报 parser 的报错,任务结束。

### 3. 运行 step(启动服务的唯一途径)

```bash
bash "${STEP}" \
  --server-command "${REQ_WORK}/server_command.sh" \
  --parser "${PARSER}" \
  --result-root "${RESULT_ROOT:-$REQ_WORK}" \
  [--gpu-allowlist <CSV>]     # 仅当请求给出 GPU 候选时
```

- **不要**直接执行 server_command.sh 的内容,不要自己敲 sglang serve,不要绕过 STEP 脚本;
- step 会自行等卡、锁卡、选端口、启动、等 `/health`;本 step 只做一次尝试,不要重复跑。

### 4. 按结果汇报

step 会打印一行 `[start-server] STEP_RESULT=<...>` 并在 RUN_DIR 写 `started.json` 或 `failed.json`(退出码:0=OK, 2=输入/配置错, 3=RETRYABLE, 4=FATAL, 5=TIMEOUT)。

- **OK(0)**:读 `started.json`,按下面格式汇报;服务保持运行,**不要**停它、不要清理。
- **非 0**:读 `failed.json`(result/stage/error)与服务日志尾部(若存在),按下面格式汇报失败阶段与原因,**不要重试**。

## 汇报格式(最终答案按此输出,不要加无关内容)

```
结果: <OK|RETRYABLE|FATAL|TIMEOUT|输入错误>
- PID/PGID: <OK 时>
- 端口: <OK 时>
- GPU: <OK 时>
- server 日志: <路径>
- 结果文件: <started.json 或 failed.json 路径>
- 说明: <一行;失败时 = stage + 关键错误>
```

## 纪律

1. 只做上面一件事;不改无关文件、不装依赖、不碰工作区以外路径、不杀其他进程。
2. 服务成功后本任务即结束(一次一任务);后续"查状态/停服务"由调用方另行发起。
3. 请求未内联命令且 `/home/server_command.sh` 不存在(即无命令来源)/ 模型路径不存在 / 校验失败 → 直接按"输入错误"汇报,不要猜、不要补。
