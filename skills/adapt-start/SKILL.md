---
name: adapt-start
description: '把新版本 sglang 适配到能正常启动:循环"真实启动(adapt-attempt) → 读 attempt.json → 无进展则退/有进展则照 origin/v0.5.12_dev 移植 → 再启动";启动成功后用 curl-smoke 确定性判定输出是否乱码。Use when: 新版本/新分支启动报代码类错误(AttributeError、算子符号缺失、签名变化等),要求"照旧版改/适配到能启动/让它跑起来",或提到 adapt-start。'
whenToUse: 'sglang 启动在 CUDA graph / 模型加载阶段报代码类错误,需要把当前版本代码适配到能启动,并验证输出正常时。'
---

# 新版本 sglang 启动适配(adapt-start)

你是一次性编排代理。**所有机械动作都执行现成 step,不许临场发明命令**;你只负责两件需要判断的事:**读 attempt.json 做分流/推进判定** 和 **把旧版(origin/v0.5.12_dev)的实现移植到新版文件**。改动绝不 commit,只留工作区 diff。

## 路径与固定参数

- `AUTO_WORK` 默认 `/home/auto-work`(代码根);step 目录 `${AUTO_WORK}/steps/`
  - `start-server.sh`(单次真实启动;由 adapt-attempt 调用,你不直接调)
  - `adapt-attempt.sh`(每次启动 → 产出 attempt.json:ok/code/stage/error/**signature**/sglang_file/sglang_line/server_log/**started_json**/**failed_json**)
  - `curl-smoke.sh`(启动成功后的 curl 冒烟 + 确定性 verdict)
- **`RUNS_DIR` 默认 `/home/runs`**(运行时数据根,与 start-server 布局对齐;不再用 ${AUTO_WORK}/runs)
- 本轮根:`ADAPT_RUN = ${RUNS_DIR}/adapt-<时间戳>/`,迭代目录 `iter-001`、`iter-002` …
  - 每轮 iter 目录内:`server_command.sh`(拷贝)+ `start-<ts>/`(start-server 产物)+ `attempt.json`
- sglang 源码:`/home/sglang-das`(用户给了则以用户为准)
- **对比基准分支:默认 `origin/v0.5.12_dev`**(旧适配版);用户给其它分支/tag 以用户为准
- 命令源:用户内联启动命令 > `/home/server_command.sh`

## 前置(任一不满足 → "输入错误"汇报退出,不进循环)

1. `echo ok` 能跑(否则先设 `DSH_PERMISSION_MODE=danger-full-access`);
2. `[ -f /home/server_command.sh ]`(若命令源用它;不存在 → 输入错误);并用 parser `metadata` 快速校验一次;
3. `git -C /home/sglang-das rev-parse --is-inside-work-tree` 通过;
4. 基准可解析:`git -C /home/sglang-das rev-parse --verify 'origin/v0.5.12_dev^{commit}'`(用户给了基准就用用户的)。

## 循环(iter=1..15)

开始前(只做一次):
1. `ADAPT_RUN="${RUNS_DIR:-/home/runs}/adapt-$(date +'%Y%m%d_%H%M%S')"; mkdir -p "$ADAPT_RUN"`;
2. **准备命令源** `${ADAPT_RUN}/server_command.sh`:请求内联命令 → 规范化写入;否则 `cp /home/server_command.sh ${ADAPT_RUN}/server_command.sh`(该文件不存在且无内联 → 输入错误退出);
3. 创建总台账 `${ADAPT_RUN}/MODIFICATIONS.md`,表头一行 `# 适配修改台账(编号 | 问题/日志 | 方案 diff | 验证结果)`,之后每轮追加一行。

**终止条件(任一命中即停,绝不无限循环)**:
1. 启动成功(`attempt.json.ok == true`)→ 走成功路径;
2. 非代码类失败(stage ∈ acquire/reserve-port 等或无 signature)→ 原地退出;
3. **无进展**(signature 与上一轮相同)或**循环**(与更早轮次相同)→ 回退本轮改动后原地退出;
4. 迭代数超过 `MAX_ITER`(默认 **15**,用户可指定)→ 原地退出,附全部迭代记录与当前日志。

每一轮:**先跑 step,再读 JSON,只按 JSON 字段决策**。禁止靠"读日志猜"代替 attempt.json。

### 1) 真实启动(固定命令,照抄,不要改)

```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/adapt-attempt.sh" \
  --run-dir "${ADAPT_RUN}/iter-$(printf '%03d' $iter)" \
  --server-command "${ADAPT_RUN}/server_command.sh" \
  --parser "${AUTO_WORK:-/home/auto-work}/lib/server_command_parser.py" \
  --src-dir /home/sglang-das
```

(adapt-attempt 会把命令源拷进 iter 目录,再以该目录为 result-root 调 start-server;本轮 `start-<ts>/started.json|failed.json|server.log` 与 `attempt.json` 都在 iter 目录里。)

### 2) 只读 `attempt.json` 分流

读 `${ADAPT_RUN}/iter-NNN/attempt.json` 字段(`ok`/`stage`/`signature`/`sglang_file`/`sglang_line`/`server_log`/`started_json`/`failed_json`):

- `ok == true` → 跳出循环,走"成功路径";
- `ok == false` 且 `stage` ∈ 非代码类(acquire/reserve-port/timeout/cleanup 及无 signature)→ 非适配问题,原地退出按失败汇报;
- `ok == false` 且 `signature` 非空(代码类)→ 继续。

### 3) 推进判定(与全部历史精确比较,防振荡)

维护一份 `signatures.log`(每轮一行)或直接扫各 `iter-*/attempt.json` 的 `signature`:

- `signature` 与 **任何一轮**历史完全相同:
  - 与上一轮(`iter-NNN-1`)相同 → **无进展**:只对本轮改过的文件执行 `git -C /home/sglang-das checkout -- <文件>` 回退,原地退出汇报"第 N 轮无进展",附两轮 attempt.json 与 server_log 尾部;
  - 与更早某轮 M 相同(A→B→A 振荡)→ **检测到循环**:回退本轮改动,原地退出汇报"第 N 轮与第 M 轮 signature 相同(疑似循环)",附两轮 attempt.json 与 server_log;
- 否则(全新 signature)→ 有进展,继续。

### 4) 移植 + 记录(修改过程全程留痕)

1. **读取证据**:`attempt.json` 的 `sglang_file`/`sglang_line`/`signature`,以及 `server_log` **绝对路径**(这就是"这轮遇到什么问题"的日志位置)。
2. **备份本轮修改前状态**:`cp "$sglang_file" "${ADAPT_RUN}/iter-NNN/file_before.py"`(若上一轮已改过同一文件,备份的是"上一轮之后"的状态 → 保证 diff 只含**本轮**改动)。
3. 查旧版:读 attempt.json 的 `sglang_file`、`sglang_line`,用 read 看该文件出错点上下文;取旧版同文件 `git -C /home/sglang-das show origin/v0.5.12_dev:<sglang_file>`,对照出错段找旧写法;必要时 `git log -S '<错误符号>' -- <sglang_file>` 补充线索。
4. 用 edit 在该文件做**单点最小修改**,把旧做法移植过来;**不改 torch/vllm、不装包、不重构**。
5. **写本轮记录(编辑完立即做,不许跳过)**:
   - 生成具体 diff:
     ```bash
     diff -u "${ADAPT_RUN}/iter-NNN/file_before.py" "${sglang_file}" \
       > "${ADAPT_RUN}/iter-NNN/change.diff"
     ```
   - 写 `${ADAPT_RUN}/iter-NNN/record.md`,按此模板:
     ```markdown
     # iter-NNN 修改记录
     ## 问题(本轮遇到的错误)
     - signature: <attempt.json.signature>
     - 位置: <sglang_file>:<sglang_line>
     - 日志: <server_log 绝对路径>
     - 错误摘录: <≤5 行>
     ## 方案(本轮修改)
     - 依据: origin/v0.5.12_dev:<sglang_file> 的 <行号/函数段>
     - diff: 见 change.diff;关键 hunk 如下
     ````diff
     <change.diff 内容>
     ````
     - 状态: 待下一轮验证
     ```
   - 追加总台账 `${ADAPT_RUN}/MODIFICATIONS.md`(同上的 编号 | 问题/日志路径 | 方案(diff 路径) | 状态)。
6. 下一轮 `attempt(N+1)` 结果出来后,**先回填**上一条台账与 record.md 的状态:验证结果 = `ok` / 推进到新 signature(`<…>`)/ 同签名无进展;再继续处理本轮。

## 成功路径(启动已 OK)

1. 读最后一轮 `attempt.json` 的 **`started_json`**(成功那轮的绝对路径),执行:

```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/curl-smoke.sh" \
  --started-json <attempt.json.started_json 的值>
```

2. 读同目录 `smoke.json` 的 `verdict`(`ok|garbled|empty|http_error|json_error`)与 `content` 样例;
3. **`verdict == ok`(测试通过)→ 最后退出服务、释放占用的卡,再汇报**(不再保留运行中的服务):
   - 读成功轮 `started.json` 的 `pid`/`pgid`/`gpus_csv`;
   - 停掉该服务进程组(沿用 start-server 的清理语义 TERM → 最多等 15s → KILL,照抄不要改):
     ```bash
     PID=<started.json.pid>; PGID=<started.json.pgid>
     if [[ "$PGID" =~ ^[0-9]+$ && "$PGID" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]]; then
       TARGET="-$PGID"
     else
       TARGET="$PID"          # PGID 记录失效时退化为按 PID 停
     fi
     kill -TERM -- "$TARGET" 2>/dev/null || true
     # 随后每秒 kill -0 -- "$TARGET" 检查一次,≤15s 仍存活则 kill -KILL -- "$TARGET"
     ```
   - GPU/端口锁 fd 由服务进程组继承自 start-server:进程退出即自动释放(flock 随 fd 关闭释放,**锁文件不删除**),无需额外操作;
   - 停服后用 `rocm-smi` 复核 `gpus_csv` 内各卡显存/利用率已回落,确认卡已释放;
   - 汇报注明**服务已退出、GPU 已释放**(pid/pgid 只作历史记录,不再是运行中的服务)。
4. `verdict != ok`(garbled/empty/http_error/json_error)→ 维持原行为:服务**保持运行不清理**(汇报 PGID 即可),留待继续排查。

## 汇报格式

成功:

```
结果: 适配成功;测试通过后已退出服务并释放 GPU(verdict=ok)
- server(历史记录,已停): pid/pgid=.., port=.., gpu=.., server 日志=<路径>
- 清理: 已停服务进程组(TERM→KILL);GPU/端口锁随进程退出自动释放,rocm-smi 复核 gpus 已空闲
- 改动: <git -C /home/sglang-das diff --stat 摘要>
- 迭代记录: <adapt 根目录,共 N 轮;每轮 attempt.json>
- 修改台账: <${ADAPT_RUN}/MODIFICATIONS.md(每轮 问题/日志路径/change.diff/验证结果)>
- curl 冒烟: verdict=<smoke.json.verdict>, 原文=<content 前 80 字…>
- 乱码判定: <正常|异常(疑似乱码)> —— 依据 verdict
```

失败:

```
结果: <无进展退出|非适配类失败|超 15 轮|输入错误>
- 第几轮: <NN>
- attempt.json: ok=.. stage=.. signature=..
- 证据: <server_log 尾部几行>
- 是否回退: <回退了本轮改动(git checkout) / 未产生改动>
- 台账: <${ADAPT_RUN}/MODIFICATIONS.md + 最后一轮 record.md 路径>
- 建议: <如"对比 origin/v0.5.12_dev 的 <file> 第 N 行" 或 "需人工判断">
```

## 纪律

1. **只按 JSON 决策**:分流/推进判定用 attempt.json 字段与字符串比较,不用自然语言猜测。
2. **命令照抄**:循环里的 step 命令逐字执行;要调参数先在本轮记录里写明理由。
3. **单点修改 + 证据**:一轮只改 sglang_file 一处;每轮必须产出 `attempt.json`/`server.log` + `record.md`/`change.diff`,并把结果回填进台账 `MODIFICATIONS.md`。
4. **绝不 `git commit`**;无进展回退仅 `git checkout -- <该轮改过的文件>`。
5. 只动 `/home/sglang-das` 下 traceback 指到的 python 文件;不动依赖、不换环境、不装包。
6. 一次一任务:汇报后结束;工作区 diff 保留,是否提交由用户决定。
