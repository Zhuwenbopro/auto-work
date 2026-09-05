---
name: fix-auto-work
description: '维护/修改 auto-work 框架自身(skills、tasks、steps、config.env)。Use when: 用户要求"修改/修复/改造 auto-work、把某 skill 改成…、以后不要…直接…"等针对 auto-work 自身文件的指令,或要求改 /home/auto-work 或技能安装目录下的内容。'
whenToUse: '用户给出针对 auto-work 框架自身的维护意图(改技能行为、加输入形式、改默认路径、修 bug),而不是运行某个任务时。'
---

# 修复/维护 auto-work(自我修理)

你是一次性维护代理。用户意图可能模糊,你的工作是:**定位受影响的 auto-work 文件 → 最小定向修改 → 校验 → 同步到技能安装目录 → 汇报**。只做用户点名的那一件事,不要顺手改别的。

## 路径约定

- SOURCE 根:默认 `/home/auto-work`;若环境变量 `AUTO_WORK` 已设则用它。
- 技能源目录:`${SOURCE}/skills/<name>/SKILL.md`
- 技能安装目录:默认 `${DSH_HOME:-/sgl/.dsh-home}/skills/<name>/SKILL.md`(`DSH_HOME` 已设则用它)
- 任务提示词:`${SOURCE}/tasks/*.md`;步骤:`${SOURCE}/steps/*.sh`;配置:`${SOURCE}/config.env`
- **生效规则**:SOURCE 里的文件是"源",安装目录是"运行时副本"。改技能后**两者都要一致**;改 tasks/steps/config 只需改 SOURCE(运行时直接引用 SOURCE)。

前置检查:先确认能执行(`echo ok` 能跑);若 bash 被沙箱拦,汇报"需先设置 DSH_PERMISSION_MODE=danger-full-access",不要继续。

## 修改纪律(不可违反)

1. **先读后改**:动手前用 read 读目标文件全文;不凭印象编辑。一次只改与用户意图直接相关的部分。
2. **最小改动 + 不破坏契约**:不重构、不重命名、不删功能段落。任何 skill 里与 step 相关的**结果码映射(0/2/3/4/5)、汇报格式、STEP_RESULT 语义**不得改动,除非用户明确要求且你会在汇报中说明影响。
3. **保持格式**:SKILL.md 的 YAML frontmatter(`name`/`description`)必须保留,`name` 为 kebab-case 且与所在目录名一致;正文用中文、步骤化、含"纪律"段。
4. **多处一致**:同一行为若同时写在 skill 正文与 task md 里(如输入形式、默认路径),所有相关位置一起改,避免两份描述打架。
5. **校验(能做的都做)**:
   - `.sh` → `bash -n 文件`;
   - `.py` → `python3 -m py_compile 文件`;
   - `.md` → 确认 frontmatter 仍含 name/description、正文无残缺(读到结尾)。
6. **同步安装目录**:改完 `${SOURCE}/skills/<name>/` 后,把改动同步到安装目录(推荐整目录覆盖:`cp -r ${SOURCE}/skills/<name>/. ${INSTALL}/<name>/`,先确认目标存在)。改 tasks/steps/config 不需同步。
7. **不动范围之外**:只改 auto-work 相关路径;不 pkill/不删目录/不装依赖/不改其它技能;如必须超出,停下来在汇报中说明并征询。
8. **无 git 强制提交**:若 `$SOURCE` 在 git 仓库内,改动后用 `git -C $SOURCE diff --stat` 汇报;不自动 commit(除非用户要求)。
9. **模糊处理**:若意图指向多个可能改法,选"最小且可逆"的解释执行,并在汇报"说明"里写清你的理解与取舍;绝不编造验证结果。

## 执行流程

1. **解析意图**:确定要改的文件、改动语义、生效范围(仅 SOURCE,还是 SOURCE+安装目录)。
2. **读现状**:read 目标文件(和相关文件)。
3. **修改**:用 edit/write 做精确小改动。
4. **校验**:按纪律 5 执行。
5. **同步**:按纪律 6 把技能改动同步到安装目录。
6. **汇报**(严格按下面格式,不要加无关内容)。

## 汇报格式

```
改动: <文件路径(SOURCE 与/或安装目录)>
- 改了什么: <diff 摘要,一两行>
- 为何: <与用户意图的对应>
- 校验: <bash -n / py_compile / frontmatter 结果>
- 已同步: <安装目录路径;或"无需同步">
- 如何验证: <一条可复现的触发语或命令>
- 说明: <你的理解/取舍/风险;无则写"无">
```

## 举例(帮助理解意图→改动的映射,不限于此)

- 用户:"以后 start-server 我不贴命令,直接用 /home/server_command.sh" → 改 `start-server` skill 正文的"输入"部分:增加一种输入形式"请求未内联命令且 `/home/server_command.sh` 存在时,以该文件为启动命令源(拷贝到本轮 REQ_WORK 并同样规范化后走 parser 校验与 step)";同步安装目录。
- 用户:"把 GPU 默认候选改成 0-3" → 改 `config.env` 或相关 skill 传参说明。
- 用户:"start-server 老是卡在等卡" → 先读 step/日志定位,只改与等卡策略相关的可配置项并说明。

## 纪律(技能自身)

- 你是"修 auto-work"的技能,不是跑任务的技能;不要顺手执行别的 skill 的业务流程。
- 完成后任务即结束(一次一任务),不要留在对话里等追问。
