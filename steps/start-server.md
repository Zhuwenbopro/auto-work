# step: start-server(启动 SGLang 服务)

> 状态:草案 v1,待确认点见文末。
> 层级:step(task 内的原子步,单一职责,零 LLM 决策)。
> 归属任务:eval / bench-serving / tracing / compare-eval 共用。

## 职责一句话

在候选 GPU 上把给定的 server 命令部署到**服务健康就绪**:

- 成功 → 返回 `OK` + `started.json`(PID/端口/GPU/日志路径等交接信息);
- 失败 → 返回结果码(`FATAL`/`TIMEOUT`/`RETRYABLE`)+ **服务日志位置**与首错摘录,并自行清理本次占用的资源。

## 输入契约

| 输入 | 必填 | 来源/说明 |
|---|---|---|
| `server_command.sh` | 是 | 规范化后的启动命令文件:`export`/`unset` 行 + 一条 `sglang serve`(或 `python -m sglang.launch_server`) |
| 配置文件 `config.env` | 是 | 默认参数(见下),argv 覆盖优先 |
| `--gpu-allowlist CSV` | 否 | 只在这组 GPU 内等待/锁定 |
| `--result-root PATH` | 否 | RUN_DIR 的父目录(默认 `/home/.../results`) |

配置文件关键项(沿用并统一现有各 task 的参数):

```
HOST / HEALTH_HOST        # HEALTH_HOST 用于服务在 0.0.0.0 时探测
START_PORT / END_PORT     # 端口分配范围
PORT_LOCK_DIR             # 端口锁目录(并发实例防撞)
SERVER_START_TIMEOUT      # 等健康超时(默认 600s)
HEALTH_CHECK_INTERVAL     # 健康探测间隔(默认 2s)
GPU_VRAM_MAX_PERCENT      # 卡空闲判据:显存占用 < x%
GPU_HCU_MAX_PERCENT       # 卡空闲判据:HCU 利用率 ≤ y%
GPU_POLL_INTERVAL         # 等卡轮询间隔
GPU_CONFIRM_SECONDS       # 锁定后二次确认窗口
SHUTDOWN_TIMEOUT          # 停服 TERM→KILL 超时
FAILURE_LOG_LINES         # 失败时日志摘录行数(默认 100)
```

## 输入规范化与校验(最先做;失败 = `FATAL`,不碰任何资源)

1. 从用户命令中剥离固定端口与设备绑定:移除 `--port` 及其值(规则:一律删,不用纠结——parser `run` 阶段会先把残留 `--port` 全部移除、再在末尾追加 step 所选端口,漏删也会被覆盖、不会按原端口启动;删除只为文件形态统一)、`HIP_VISIBLE_DEVICES` 赋值/export、`nohup`、尾部 `&`、输出重定向;保留 `export`/`unset` 与其余参数;拒绝管道、命令替换等与服务启动无关的构造。
2. 校验:
   ```bash
   python3 lib/server_command_parser.py metadata ./server_command.sh   # exit 0 才通过
   bash -n ./server_command.sh
   ```
3. 解析 `--tp-size × --pp-size` → 所需 GPU 数 N(缺省各为 1)。

## 内部阶段(失败定位粒度;对外仍是一个职责、一个谓词)

| 阶段 | 动作 | 失败时 |
|---|---|---|
| 1 parse | 解析命令与 N 卡数 | `FATAL`(parser 报错,未占资源) |
| 2 acquire | 在 allowlist 或全部 GPU 内按空闲阈值轮询找 N 张卡,`flock` 锁定,短暂二次确认 | 等卡超时(若设上限)→ `TIMEOUT`;未占资源 |
| 3 reserve-port | 在 `START_PORT..END_PORT` 内经端口锁选一个端口 | 端口冲突 → 换端口重试(属 RETRYABLE 内部自愈) |
| 4 launch | 以独立进程组启动服务,stdout/stderr 全部进本轮 `server.log`,记录 PID/PGID | 进程立即退出 → 转阶段 5 判定 |
| 5 health | 轮询 `/health` 直到通过或超时 | 进程早死 → `FATAL`;存活但超时 → `TIMEOUT` |

## 成败判定与结果码

| 结果码 | 含义 | 交给 task 的动作建议 |
|---|---|---|
| `OK` | 服务健康就绪 | 读 `started.json` 交接给下游 run-* step |
| `RETRYABLE` | 资源冲突/端口被抢等可重试失败 | 可重试一次(新 RUN_DIR) |
| `FATAL` | 命令非法 / 服务启动即失败(进程退出,日志有错误) | 停,查日志 |
| `TIMEOUT` | 等卡超时或等健康超时(已回滚资源) | 按策略重试或停 |

**本 step 只做一次尝试,重试策略归上层(task/驱动器)**。

## 资源与清理语义(关键)

- **成功(`OK`)**:保留服务进程组与 GPU/端口锁,资源**交接给下游** run-* step;本 step 不清理。
- **失败(任何非 OK)**:自行清理——停掉本次启动的进程组(TERM→超时→KILL)、释放 GPU 锁与端口锁,不留残余。
- 清理幂等;锁文件不删除(释放 flock 即可)。

## 产物契约

每轮独立目录:`${RESULT_ROOT}/start-server-<timestamp>/`

- `server.log` —— 服务 stdout/stderr;
- `started.json`(OK 时):
  ```json
  { "result": "ok", "pid": 12345, "pgid": 12345, "port": 30123,
    "gpus": [0, 2], "health_url": "http://127.0.0.1:30123/health",
    "server_log": ".../server.log", "run_dir": "...",
    "model_name": "Qwen3-8B", "model_path": "/models/Qwen3-8B",
    "started_at": "...", "elapsed_s": 42 }
  ```
- `failed.json`(非 OK 时):`{ "result": "fatal|timeout|retryable", "stage": "parse|acquire|reserve-port|launch|health", "server_log": "...", "error": "<首错摘录,≤FAILURE_LOG_LINES 行>" }`

## 日志标记行(供 watcher/上层解析,保持既有风格)

```
[start-server] 等待可用 GPU(N=2)...
[start-server] GPU 已锁定: 0,2
[start-server] 端口: 30123
[start-server] SGLang 服务健康检查通过 (pid=12345, port=30123)
[start-server] SGLang Server 启动失败: <server.log 路径>
[start-server] SGLang Server 启动超时: <server.log 路径>
```

## 复用与重构来源

现有实现分散在三个任务里且互相复制:`eval/automation/auto_eval.sh`、`bench-serving/automation/auto_bench.sh`、`tracing/automation/auto_profile.sh`(均为 ~400–500 行,内含"等卡锁卡→选端口→起服务→等健康→清理")。

目标:**提炼为 `steps/start-server.sh` + `steps/lib/`(命令 parser、GPU 锁、端口锁、进程组/日志工具)**,三个 task 共用一份;差异(等卡策略、清理归属)由配置与调用方控制。

## 待确认点

1. **端口**(已定):总是由 step 自动分配;固定 `--port` 一律剥离,parser `run` 阶段以所选端口覆盖残留 `--port`,故剥离只影响文件形态,不影响最终启动(不保留用户显式端口)。
2. **等卡语义**:默认无限等待(像现在 `MAX_ATTEMPTS=0`),还是默认有界(超时 → `TIMEOUT`)?重试归上层?
3. **成功资源交接 / 失败自清理**语义是否认可?(OK 后本 step 不清,由后续 release 或 task 收尾)
4. **结果码四档**(OK/RETRYABLE/FATAL/TIMEOUT)是否采用?
5. 等健康期间"进程早死"与"活着但超时"分开成 FATAL/TIMEOUT,认可吗?
