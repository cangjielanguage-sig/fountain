# Design：x86_64 strictFp ÷0 与回边安全点

## 1. 根因

### 1.1 `FDIV_CHK` 谓词写反（`X86Lower.cj:472–487`）

```asm
xorps   xmm1, xmm1
ucomisd xmm1, [rsp]      ; 与除数比较
jnp     go               ; ← 错：有序（含 0.0）就跳走，零检查被跳过
jz      z                ; 只有无序才走到这里
go:     divsd xmm0, [rsp]
        jmp done
z:      bail(1)
done:
```

`jnp`（PF=0 ⇔ 有序）把 **正常的 0.0** 也放行 ⇒ 永不 `bail(1)`。
应为 **`jp`**（PF=1 ⇔ 无序/NaN 才跳过零检查），随后 `jz z` 在 ZF=1（相等）时 `bail(1)`。

### 1.2 `LOOP_BACK` 缺安全点（`X86Lower.cj:1000–1002`）

x86 只发 `jmp`；而：

- aarch64：`A64Lower.cj:359–369` → **STACK_GUARD**（`fp - frame - sp < frame ⇒ deopt`）+ **H22**
  + 跳转；
- 解释器：`Interp.cj:576–578` → 回边调 `INTERRUPT_POLL` 再跳。

⇒ x86 上既无期限轮询（`p0_6_deadlineInterruptsLoop` 跑完不中断），也无栈余量 deopt
（与 aarch64 的语义分叉，属 I7 面缺口）。

## 2. 修复

### 2.1 谓词

`floatDivChk` 首个 `jcc(0x8Bu8, go)` → `jcc(0x8Au8, go)`（`jp`）。

### 2.2 回边

`case 0x74u8` 在 `jmp` 前补：

```asm
; STACK_GUARD：rax = (rbp - frame) - rsp ; rdx = frame ; cmp ; jge ok
mov  rax, rbp
mov  rdx, frame
sub  rax, rdx        ; 48 29 D0
sub  rax, rsp        ; 48 29 E0
mov  rdx, frame
cmp  rax, rdx        ; 48 39 D0
jge  ok              ; 0F 8D
mov  qword [r15+0], -1   ; deopt
jmp  epilogue
ok:
; H22 interrupt_poll（变体 0：占位 + 自动 CHECK_ERR）
call h_dispatch(22, ctx, null, 0)
add  rsp, 8          ; 丢弃占位
```

- `frameSize` 取 `BackendX86_64.frameSize(nLocals, maxStack)`（与序言同一公式）；
- `errCode = -1` 直接跳 `epilogue`（**不走** `checkfail`，避免 -1 触发转储；
  与 `bail(k ≤ 0)` 的既有分派一致）；
- `interrupt_poll` 用变体 0（自动 `CHECK_ERR`）；返回占位出栈保持栈平衡。

## 3. 不变项

字节码格式 / opcode / helper / 错误码 / aarch64 / 三引擎语义均不变；deopt 仍由桥透明重放。

## 4. 测试

- **RED（既有 4 例）**：`defaultIsStrict` / `strictDivisionByZeroFails` / `strictFpIsPartOfCacheKey` /
  `p0_6_deadlineInterruptsLoop`——修复前 FAILED（本轮实测）。
- **GREEN 判据**：4 例转绿；全量 **1098/1098（0 ERROR / 0 FAILED）**。
- **护栏**：`X86Lower_test` 增 1 条字节断言（`FDIV_CHK` 首个条件跳转为 `0F 8A`）；
  回边护栏由 `p0_6_deadlineInterruptsLoop` 行为用例承担（栈余量分支由既有 deopt 用例覆盖）。
- **回归**：差分 11 例、`PerfCompare`（回边多两条检查，记录数字）。

## 5. 风险

| 项 | 说明 |
|---|---|
| 循环开销 | 回边新增约 12 条指令（比较 + 一次 helper 调用）；`PerfCompare` 复测 |
| 期限轮询频率 | 与 aarch64 完全一致（每回边一次） |
| deopt 触发面 | 仅在余量不足时触发，语义透明（既有纪律） |
