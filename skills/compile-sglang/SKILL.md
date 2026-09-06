---
name: compile-sglang
description: '编译并安装 HYGON-AI sglang-das 到当前 Python 环境(HCU/ROCm):编译 sgl-kernel AOT、editable 安装 sglang,并验证 import 与 kernel 包(镜像已含依赖,不装 requirements);支持指定远程分支编译:请求带“<分支> 分支”(如 release/20260825_v0.5.18)时先确认该分支存在(不存在直接报错),存在则检出后编译;未指定则按 main 分支编译。Use when: 用户要求编译/构建/重装 sglang、sglang-kernel、sgl-kernel、HIP/HCU 支持,或提到 compile-sglang。'
whenToUse: '用户要求编译/构建/安装/重装 sglang 或 sgl-kernel(HCU/ROCm)时;本技能不做 GPU 评测等其它事。'
---

# 编译并安装 SGLang(HCU/ROCm)

你是一次性执行代理,只做"编译+验证"这一件事。底层是确定性 step,不要自行拼命令。

## 路径

- STEP 脚本:`${AUTO_WORK:-/home/auto-work}/steps/compile-sglang.sh`
- 结果根:`/home/runs`(日志/pid/json 写这里)

## 输入

- 源码目录:用户给了就用用户的(绝对路径);没给默认 `/home/sglang-das`(不存在才 clone,已有则复用,不删除不覆盖)。
- 分支(可选,默认 `main`):请求里带明确分支就用该分支,否则按 `main` 分支编译。例:“用 compile-sglang 技能编译 sglang 的 `release/20260825_v0.5.18` 分支”→ 分支 = `release/20260825_v0.5.18`。
- 其余无参数;编译装进**当前 Python 环境**,不要换环境、不要加 sudo。

## 说明(本环境)

- 镜像已含运行/编译依赖,**不再安装 requirements_hcu.txt**(step 已删除该步)。
- `build-aot-kernel` **只编译算子**:产物走本地 wheel 离线安装(`bdist_wheel` + `pip3 install --no-deps --no-index`),**不从 PyPI 下载/更新任何依赖**。kernel 编译要求本机 `rustc`/`cargo` **≥ 1.92**:step 在 build-aot-kernel 前先校验版本,缺失或不足时**自动下载/升级 Rust 工具链**(默认 rustup,无 rustup 则官方脚本 `sh.rustup.rs` 装 1.92.0;整条安装命令可用环境变量 `RUST_INSTALL_CMD` 覆盖)并**继续编译(自动重试)**;仅当升级失败或升级后仍不足才失败。**其它失败不做自愈**,直接失败汇报(看 stage 与日志尾部)。

## 执行流程

### 1. 前置检查

- `echo ok` 能跑(执行权限);不能则汇报"需先设置 DSH_PERMISSION_MODE=danger-full-access"。
- 没有其它 compile-* 正在跑(检查 `${RESULT_ROOT}/compile-*/compile.pid` 对应进程是否存活);有则汇报冲突,不并发编译(会互相踩 pip/编译产物)。
- `bash -n` 语法检查 step(一次性,防部署时文件损坏)。

### 2. 确定分支(切换分支这一步;解析 → 传入 step)

- 请求带明确分支(如“用 compile-sglang 技能编译 sglang 的 `release/20260825_v0.5.18` 分支”)→ 分支名 = “分支”二字前最近的不含空格的词/路径段(`release/20260825_v0.5.18`);请求里**没有任何分支** → `main`。
- 分支**是否存在于远程由 step 确认,技能不要预判、不要自行拼 git 命令**:step 编译开始先进入 `stage=checkout`——分支不存在 → 直接 `RESULT=FATAL stage=checkout` 报错,不进入编译;存在 → `git fetch origin <分支>` 并检出该分支后再编译。缺省 `main` 也走同一确认+检出,保证“无分支=编译 main”;远端暂不可达但本地已有同名分支时按本地检出,离线复用不阻塞。
- 把分支名作为 `--branch` 拼进下一条启动命令(未指定分支传 `main`)。

### 3. 启动编译(async,防单次调用超时)

```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/compile-sglang.sh" start \
  --src-dir "<源码目录>" --branch "<分支,无则 main>" --result-root "/home/runs"
```

预期输出:`COMPILE_RESULT=STARTED pid=... branch=<分支> log=... run_dir=...`。记下 pid 与 log。

### 4. 轮询直到完成(可多轮,每次 wait ≤50s)

```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/compile-sglang.sh" wait <pid> 50 \
  --result-root "/home/runs"
```

循环调用直到出现 `COMPILE_STATE=done`;单次 wait 超过 50s 没结束属正常(会返回 running),继续下一次 wait。**上限**:累计约 2.5 小时仍 running → 按"仍在进行"汇报并给 log,让用户决定是否继续等。

### 5. 汇报(严格按格式)

```
结果: <OK|FATAL|输入错误|仍在进行>
- 源码目录: <路径>
- 分支: <请求给出的分支,无则为 main>
- 阶段: <失败时:stage=clone/checkout/uninstall-kernel/build-aot-kernel/install-editable/verify-import/verify-kernel>
- 编译日志: <log 路径>
- compile.json: <json 路径>
- 说明: <OK = "sglang import: OK + pip show sglang-kernel 存在";失败 = 日志尾部首错摘录(几行),分支不存在时应摘录 FATAL stage=checkout 的 reason;仍在进行 = 已等待时长>
```

## 纪律

1. 只做编译+验证这一件事;不跑评测/压测、不装无关依赖、不动 auto-work 以外路径。
2. 失败即停(step 已保证):除 Rust 工具链不足时由 step **自动升级后继续编译**外,不要自动改安装策略重试;若日志显示 `--no-index` 缺 wheel,把缺失包与精确失败命令汇报给用户,不悄悄改策略。若失败为 Rust 自动升级失败/升级后仍 < 1.92,汇报当前版本、要求(≥ 1.92)与 `RUST_INSTALL_CMD` 覆盖方式。
3. 中途不要在另一终端并发跑 pip/编译;结束后不需要清理(产物/日志留作证据)。
4. 一次一任务:汇报后任务结束;如需重编,用户另发起。
