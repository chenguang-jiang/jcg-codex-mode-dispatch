---
name: jcg-codex-mode-dispatch
description: ONLY use when the user explicitly invokes this skill (e.g. "/skill:jcg-codex-mode-dispatch") or explicitly asks for multi-model PARALLEL dispatch. CRITICAL COST MODEL: every `codex exec` sub-agent pays a FIXED ~35-45s startup tax (plugin load + model refresh + websocket prewarm + MCP retries) BEFORE any work starts — measured on this machine. So this skill is ONLY worth it when there are MANY (>=3) genuinely independent subtasks whose parallel speedup beats doing them in the main thread. Do NOT use for: a single task, a question you can answer directly, anything solvable in the main thread in under ~60s, <3 subtasks, tightly-coupled sequential work, single trivial edits, or any task the user did not ask to parallelize. When it IS used: splits the task into independent subtasks, runs them in PARALLEL as separate `codex exec` sub-agents via scripts/dispatch.sh, routing each to gpt-5.6-luna (ONLY for machine-verifiable output) or gpt-5.6-sol (everything else + final synthesis); gpt-5.6-terra optional. Accuracy > latency > cost. Features fail-closed dispatch, per-subtask machine verification, Luna->Sol automatic failover, and dual-run cross-validation for high-stakes work.
disable-model-invocation: true
metadata:
  priority: accuracy > latency > cost
  routing:
    simple_machine_verifiable: gpt-5.6-luna
    complex_or_unverified_or_synthesis: gpt-5.6-sol
    mid_optional: gpt-5.6-terra
---

# JCG Codex Mode Dispatch

你（主 agent）是**编排者**。你自己不干大块粗活，也**不能在运行中切换自己的模型**——"用 Luna"= **spawn 一个 Luna 的 `codex exec` 子进程**去干，主会话模型不变。

> 本 skill 走 **shell 嵌套 `codex exec`** 路线（非 codex 原生 `spawn_agent`），`-m` 显式指定模型，**不受 MultiAgent V2 / Sol 路由回归坑影响**。

## 启动门槛（第一道闸，先读这条）

**每个 `codex exec` 子进程有 ~35-45 秒固定启动税**（插件加载 + 模型刷新 + websocket prewarm + MCP 重试），在干活之前就要付，与本机实测一致。这意味着：

- **子任务数 < 3 → 禁止用本 skill**，直接主线程做。
- **任意子任务主线程能在 ~60 秒内答完 → 禁止路由到 exec**（37s 启动税 + 跑 > 直接做）。
- **单个简单问题 / 一次问答 / 一处小改 → 禁止用本 skill**，直接答。
- 只有当 **N≥3 个真正独立的子任务**，且并行后总时间明显小于串行主线程时，才值得付启动税。
- 即使用户点名触发本 skill，你仍要先判断：若不满足门槛，**告诉用户"这事不值得并行，我直接做"然后直接做**，不要为了用而用。

**派发前自检三问**：(1) 子任务≥3 个且相互独立？(2) 每个都 > 60 秒、非主线程能秒答？(3) 并行总收益 > 启动税 + 协调成本？**三问全 yes 才派发**；任一 no → 主线程直接做。

## 优先级（铁律，不可商量）：accuracy > latency > cost

- 默认偏 **Sol**：任何**正确性无法被机器校验**的子任务 → 用 Sol。
- 只把**带机器校验步骤**的子任务交给 Luna（schema 校验、跑测试、lint、regex/parse 校验）。**无校验 → 不用 Luna。**
- **effort 地板**：Luna ≥ medium（强校验才允许 low）；Sol 关键活 ≥ high；reduce 步骤 = xhigh。
- 拿不准 → 默认 Sol，或走**双跑**（Luna+Sol 各跑一份比对）。

## Dispatch Gate（失败关闭）

- dispatch.sh 对 **model 为空/非法**的行**直接报错退出，不 fallback**到任何默认模型。路由错=结果错，宁可停。
- 子 agent 收到的 prompt 必须含 `agent_type`（见 tsv），这是本 skill 的"角色标签 + 模型 + 校验 + 权限"封装；**没有有效的 model+agent_type → 不派发**。

## Dispatch Contract（派发契约，七字段，缺一不派）

每次派发前，让子 prompt（或 tsv 注释）自包含这 7 个字段：

- `Outcome`：子任务必须返回的、可独立完成的产物。
- `Benefit`：相对留在主线程做，这次并行带来的实际收益（省上下文/省时间/独立判断）。
- `Sources`：事实判断所需的**全部**路径/URL/数据。子 agent 用 `fork_turns="none"` 等价（exec 默认无父上下文），**主线程对话里的材料不会自动传给子 agent**，必须显式列出。
- `Scope`：允许的读/写、所有权、排除项、外部动作授权。
- `Checks`：验收标准 + 子 agent 自负的校验（写进 tsv 的 VERIFY_CMD）。
- `Stop when`：有界的完成/阻塞/证据阈值，到了就结束。
- `Return`：父期望的简报或产物格式。

**缺 `Outcome`/`Benefit`/必要的 `Sources`/`Checks`/`Stop when` → 不派发**，留在主线程。

## 路由表

| 子任务 | 模型 | effort 地板 | 校验 | 冗余策略 |
|---|---|---|---|---|
| 结果**可机器校验**的批量活（带 schema 提取、生成后自跑的单测、lint 修复） | `gpt-5.6-luna` | medium（强校验才 low） | **必须自带校验**，不过=失败 | **失败升档**：Luna 挂/校验不过 → dispatch.sh 自动用 Sol 重跑 |
| 语义类、无机器校验、会进最终答案（总结/翻译/改写/分析） | `gpt-5.6-sol` | high | reduce 对抗审查 | 高 stakes **双跑** |
| 架构 / 疑难 debug / 跨文件重构 / 安全审查 | `gpt-5.6-sol` | high–xhigh | reduce 审查 + 跑测试 | 高 stakes **双跑** |
| reduce / 综合 / 裁决 | `gpt-5.6-sol` | **xhigh** | 逐条质检 | —— |
| 拿不准 | `gpt-5.6-sol` 或 双跑 | —— | —— | 双跑 |

> `gpt-5.6-terra`（中档）为可选：仅当你明确想"比 Sol 省、又比 Luna 稳"时在 tsv 里手填；默认路由**不用**它。

### 失败升档 vs 双跑
- **失败升档**（串行兜底，省钱）：Luna 子任务出错或校验不过 → dispatch.sh 自动用 Sol/high 重跑同一 prompt。默认开启。
- **双跑**（并行冗余，买准确，用于高 stakes 无语义校验的活）：tsv 里对同一子任务写**两行**（同 WAVE、同 prompt、model 一行 luna 一行 sol、不同 OUTFILE），reduce 时比对——一致才采信，不一致以 Sol 为准或标红。

### 并行新定位
准确优先下，并行主要用来**跑双跑 / 多校验 / 多视角**而不爆墙钟，提速是副产品。

## 工作流（四步）

1. **先过启动门槛**（见上文）：子任务<3 或有任一能主线程秒答 → **不启动 dispatch，直接主线程做**，并告知用户。通过后才进入拆解：把任务拆成独立子任务（无共享可变状态）；画依赖、分 WAVE（波内并行、波间串行）；标 stakes 与可校验性。预期 < ~60 秒的碎活**合并**，别单独 spawn（37s 启动税不值）。
2. **指派**：按路由表给每个子任务定 model + effort + VERIFY_CMD，写 `tasks.tsv`：
   列 = `WAVE<TAB>MODEL<TAB>EFFORT<TAB>WORKDIR<TAB>OUTFILE<TAB>VERIFY_CMD<TAB>PROMPT[<TAB>SANDBOX[<TAB>DEPENDS_ON]]`
   - `VERIFY_CMD` 可空；其内部可用 `$OUT`（= OUTFILE 路径）。
   - `SANDBOX` 可空（默认 `read-only`）；**写类子任务**（生成/改文件）填 `workspace-write`。
   - `DEPENDS_ON` 可空；逗号分隔的 OUTFILE 路径——有此列的任务**绕过 wave barrier**，改为轮询等待依赖文件出现后立刻启动（DAG 模式，见下文）。
   - 双跑：同一子任务写两行（不同 MODEL/OUTFILE）。
3. **派发**：`./scripts/dispatch.sh ./tasks.tsv`（`MAX_CONCURRENCY` 默认 4，无 429 再加）。
   dispatch.sh：按波并行、DAG 依赖调度、并发上限（fifo 令牌池，bash 3.2 兼容，**不用 `wait -n`**）、单任务超时（gtimeout/timeout 自动探测，无则跳过）、跑每个 VERIFY_CMD、Luna→Sol 失败升档、投机 failover（opt-in）、写 `<tsv>.failures`。
4. **reduce + 质检**：读各 OUTFILE；读 `<tsv>.failures`；用一个 **Sol xhigh** reduce：(a) 逐条审计每份子结果而非盲拼；(b) 比对双跑对；(c) 对存疑的重跑/升档。写类子任务还要跑测试 / `git diff` 校验后才采信。最后交付。

### 轻任务合并（batch exec）

当拆解出的子任务满足以下**全部**条件时，**合并成一个 exec 行**，只付一次启动税：

- 子任务数 2–4 个
- 每个子任务预估 < 15s（简单提取/格式化/单文件小改）
- 子任务之间无依赖（合并后在一个 prompt 里串行做，顺序无关）
- 输出写到不同文件（无写冲突）

合并 prompt 模板：`"请依次完成以下 N 个独立任务，每个任务的结果写到指定文件：任务 1: … → file1；任务 2: … → file2 …"`。tsv 里只写一行，VERIFY_CMD 检查所有输出文件。

**收益**：把 2–4 次启动税压缩成 1 次，轻任务场景提速 40–70%。

### DAG 依赖调度（col 9: DEPENDS_ON）

默认 wave barrier 等**整个上一波**完成才启动下一波——如果上一波有一个慢任务（木桶效应），快任务的下游就被白等。

`DEPENDS_ON` 列让任务**绕过 wave barrier**，只等自己声明的依赖文件出现：

```tsv
1	gpt-5.6-luna	medium	.	a.txt		提取 A 的 schema
1	gpt-5.6-luna	medium	.	b.txt		提取 B 的 schema
1	gpt-5.6-sol	high	.	c.txt		分析 C（耗时 3 分钟）
2	gpt-5.6-sol	high	.	d.txt		合并 A+B 的结果	a.txt,b.txt
```

上例中 `d.txt` 只依赖 `a.txt,b.txt`——a/b 10s 完成后 d 立刻启动，**不用等 c 的 3 分钟**。

实现：dispatcher 用 `wait $wave_pids`（只等当前波次的 PID）替代 `wait`（等所有子进程），DAG 任务的 PID 记入 `dag_pids`，最终一起 wait。

### 投机 failover（speculative failover，opt-in）

默认失败升档是**串行**的：Luna 跑完 → verify 失败 → 才启动 Sol。总时延 = Luna + Sol。

设 `SPECULATIVE_FAILOVER=1` 后，Luna 启动的同时延迟 `SPECULATIVE_DELAY`（默认 30s）启动 Sol shadow：

- Luna verify 通过 → 杀掉 shadow（省资源）
- Luna 失败 → shadow 已在跑，总时延 ≈ max(Luna, delay+Sol) 而非 Luna+Sol

```bash
SPECULATIVE_FAILOVER=1 SPECULATIVE_DELAY=20 ./scripts/dispatch.sh tasks.tsv
```

**代价**：每次 Luna 任务多付一次 Sol 的启动税+部分执行时间。仅对时延敏感的高风险任务开启。

### 跳过插件加载（EXTRA_EXEC_FLAGS，实验性）

`codex exec` 每次启动都加载 config.toml 里的所有 plugin（documents/spreadsheets/browser-use/computer-use 等 8 个）和 MCP 连接——这是启动税的大头之一。

```bash
EXTRA_EXEC_FLAGS="--ignore-user-config --ignore-rules" ./scripts/dispatch.sh tasks.tsv
```

`--ignore-user-config` 跳过 config.toml 加载（auth 不受影响，`-m` 已显式指定模型）。`--ignore-rules` 跳过 execpolicy 规则文件。**先单独测一个 exec 确认不报错再用**——某些工作目录可能需要 trust_level 配置。

## 子 agent 行为纪律（写进每个子 prompt，借鉴 codex-team-mode）

- **fresh context**：子 agent 无父上下文，所有事实来源必须在 prompt 里列全；缺来源 → 子 agent 要么给定路径、要么只做"收集该证据"、要么把该切片退回主线程，**不得编造**。
- **校验即责任**：每个 `Checks` 必须跑或返回确切 blocker，才能声称完成。
- **不替父决策**：未解决的产品/架构/安全/编辑判断，留主线程；子 agent 只返回证据与阻塞。
- **partial verdict**：到 `Stop when` 立即返回**可用的部分结论**，不沉默超时、不为"做完"而编造。
- **不可替换目标**：不得用一个更简单的 proxy 偷换请求的产品目标，只因为它更好测。
- **Reviewer 独立性**：若子任务是审查，用全新上下文，**不告诉它之前的辩论/作者/怀疑点/期望结论**，最多给"一个具体未解决风险 + 精确证据 + 已通过检查 + 不要重复"。
- **不派生后代 / 不读 skill 指令**：子 agent **不得**再 spawn 子进程、**不得**加载本 skill 解释其指令；它只做本子任务的 task work。这条由 dispatch.sh 注入的精简 GUARD（3 条规则，~80 词）强制——比长 GUARD 减少注意力稀释，提高首次成功率，间接降低 failover 触发频率。

## 协调纪律（smallest-useful-set + 算协调成本）

- **能不开子 agent 就不开**：派发前说出**一个** material benefit；把 briefing、inspection、rework、waiting **以及每个子 agent ~37s 的启动税**计入协调成本；收益不覆盖成本就留主线程。**显式调用本 skill ≠ 必须开子 agent；不满足启动门槛就主线程直接做。**
- 只并行**真正独立**的工作；同一共享产物/工作树/可变系统**只保留一个写者**。
- 子报错/超时/中断 → **先查共享产物与 trace**，最多重试一次（且无可用结果时）；有可恢复产物不重做。
- 验收前**看真实产物/diff/验证输出**，不信子 agent 自述。
- 主线程保留：未解决的意图/产品/编辑/架构/安全决策 + 最终验收 + 全新架构/弱或视觉验收/导出器编译器设计/高后果安全或回滚判断。

## 查看用量（可选诊断）

```bash
python3 ~/.codex/skills/jcg-codex-mode-dispatch/scripts/usage_by_model.py --days 1
```
> 注意：`codex exec --ephemeral` 子任务可能**不写** sessions trace，用量统计以主线程与非 ephemeral 为准；仅作参考。准确优先下成本是第三优先级。

## Codex skill 合规

- 本 SKILL.md 及引用文件**由主 agent 自己读**，**绝不**把"读/解释 skill 指令"委派给子 agent（子 agent 只做 task work）。脚用相对路径 `./scripts/dispatch.sh` 调，不发明本地绝对路径。
- 子 agent 的 prompt 必须**自包含**，并以 dispatch.sh 注入的 GUARD 行结尾。

## 开关（你决定是否使用）

- **默认隐藏**（`disable-model-invocation: true`）：模型平时看不见本 skill，**绝不自动用**。触发：`/skill:jcg-codex-mode-dispatch` 或在 prompt 里点名。
- 想让模型也能自动建议 → 删掉 frontmatter 那行（description 仍约束触发，不推荐）。
- **硬关**：目录改名加 `.disabled`（如 `mv jcg-codex-mode-dispatch jcg-codex-mode-dispatch.disabled`，可逆）；或启动 `codex --no-skills`（关全部）；或移到项目级 `.codex/skills/` 按项目开关。
