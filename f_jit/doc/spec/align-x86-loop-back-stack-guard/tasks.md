# Tasks

## 1. 红（机制护栏先行）

- [x] 1.1 `X86Lower_test` 增字节断言：含 `while` 回边的单元，在 H22 调用前出现 `0F 82`（`jb`），
      且其前有 `cmp rax, rdx`（`48 39 D0`）；先确认**当前实现（无守卫）下该断言失败**
      验证：`cjpm test --filter X86Lower_test` 红

## 2. 实现 STACK_GUARD

- [x] 2.1 `X86Lower` 的 `case 0x74u8` 插入守卫：`overflow = (rbp-frame)-rsp`、`cmp overflow, frame`、
      `jb ok`、否则 `errCode=-1` + `jmp epilogue`；`frame` 取 `BackendX86_64.frameSize`
      验证：1.1 断言转绿
- [x] 2.2 H22 仍保留在守卫之后（顺序：守卫 → 轮询 → 跳转）
      验证：`p0_6_deadlineInterruptsLoop` 仍转绿（1.3ms 量级）

## 3. 回归

- [x] 3.1 全量 `cjpm test`：**1098/1098（0 ERROR / 0 FAILED）**
      验证：Summary 数字
- [x] 3.2 循环密集用例不退化：`p0_6_deadlineInterruptsLoop` 毫秒级、`PerfCompare_test` 的
      `jit=…ns` 与上一轮同量级（±30% 内）
      验证：日志中的 `PERF-M1` 数字
- [x] 3.3 差分 11 例全绿（含在 3.1 内）；deopt 透明性由既有用例覆盖
      验证：`test.diff` 全绿

## 4. 文档

- [x] 4.1 `jit-bytecode-m1.md` §12.4：把"x86 栈余量守卫为遗留项"改为**已实现**，并写清两侧
      `frame` 语义对照（A64：x20 与 sp 分离 ⇒ 正常不触发；x86：`rsp` 兼作操作数指针 ⇒ 显式比较）
      验证：规格文本可 grep 到该条且与实现一致
- [x] 4.2 `verify.md` 追加 2026-10-22 第三轮记录（对齐结论、方向教训、回归数字）
      验证：verify.md 含该条

## Workflow follow-up

- 用户要求（2026-10-22）："对齐 A64Lower.frame 的语义 + x86 LOOP_BACK 补 STACK_GUARD，再走一遍 OpenSpec 全流程"。
- 完成后 `opsx:verify`（已安装）+ `opsx:archive`。
