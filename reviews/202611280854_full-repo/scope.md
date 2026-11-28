# 审查范围

- **项目根**：`D:/docs/work/cangjie/projects/fountain`
- **审查范围**：`.`
- **默认范围**：所有 `f_*` 模块 + `fboot` / `fdbm` / `fmq` / `fprobe`；不含 `f*demo` 与 `.worktrees`
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支）
- **审查单元**：模块（一份模块一份报告，见 `modules.md`）
- **报告目录**：`docs/review/2026-11-28/`（`<module>.md`）
- **过程目录**：`D:/docs/work/cangjie/projects/fountain/reviews/202611280854_full-repo`
- **并行度**：每批 2 个子 agent

## 审查重点

- 正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点瓶颈、低性能、存量 BUG、内存/CPU 优化空间、local mode 可行性

## 本轮特别强调

（本轮未特别指定，按通用维度 + 全部专项扫）

## 已有性能资料

docs/LocalMode.md、docs/LocalMode-O2-Plan.md

## 排除

- generated/
- third_party/
- target/
- .worktrees/

## 约束

- 只读审查，不改源码、不跑构建、不提交。
- 主 Agent 不读被审源码；代码阅读由 reviewer 子 agent 完成。
- 每条发现必须给：位置（文件:行号）、来源（本次改动 / 存量）、判据（review-checklist 小节）、
  证据等级（静态确定 / 需实测 / 待确认）。
- 缺陷进「发现」，性能与内存改进进「优化可行性方案」，两者分开统计。
- **每个模块的 `.cj` 与 `.md` 全量审查**：按 `files/<module>.txt` 逐个读完（README、`doc/**` 都算），
  不做抽样、不只审 `src/`；缺一个文件或没写「文件覆盖表」即本轮未完成。
- 每审完一个模块，立即把该模块报告写到 `docs/review/2026-11-28/<module>.md`。
