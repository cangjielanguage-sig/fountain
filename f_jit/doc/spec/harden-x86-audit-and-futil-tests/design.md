# Design：x86 审计对称化 + f_util 用例执行

## 1. 问题

`d2b0b4d8`（A64）修正了"常量镜像/函数表用 `movImm64` 物化宿主绝对地址，被审计误判"。
x86 侧同一类访问**完全不经过审计点**：

| 路径 | 代码 | 说明 |
|---|---|---|
| `PUSH_KH` | `X86Lower.cj:784-791`：`mov rax, constBase+8*i` → `mov rax,[rax]` | 直接 `add([0x48,0x8B,0x00])`，不经 `movRaxMemRsp` |
| `CALL_FUNC` | `X86Lower.cj:449`：`mov rax, fnTableBase` → `mov rax,[rax+rcx*8]` | 同上 |

⇒ 现状是"漏审"：不误判，但也没有被规则覆盖；一旦审计收紧，会复现 A64 那次整单元静默回退。

## 2. 方案（对称化）

- `BackendX86_64`：
  - 新增 `noteAbsMem()`：向审计表追加哨兵 `-1`；
  - `auditAllows`：接受 `-1`（绝对地址），拒绝其余越界值。
- `X86Lower`：
  - `case 0x16`（`PUSH_KH`）在 `mov rax, constBase+8*i` 后登记 `noteAbsMem()`；
  - `callFunc` 在 `mov rax, fnTableBase` 后登记 `noteAbsMem()`。

这样两侧规则一致：**栈/帧/ctx 的受控基址 + 显式登记的宿主绝对地址**，其余一律拒绝。

## 3. 用例

| 用例 | 位置 | 断言 |
|---|---|---|
| `absoluteAddressIsExempt` | `backend/EmitAudit_test.cj` | `auditAllows([4,-1,15])==true`；`auditAllows([0])==false`；`noteAbsMem` 后快照含 `-1` |
| `plainUnitStaysJitBacked` | 新 `src/JitBacked_test.cj` | `{ x: Int64 => x + 1 }` ⇒ `isJitBacked()` 为真 |
| `constMirrorUnitStaysJitBacked` | 同上 | `{ x: Int64 => "v${x}" }` ⇒ `isJitBacked()` 为真（`PUSH_KH` 不被误判），且返回 `v7` |

## 4. f_util 用例执行

仓库无 CI 配置，采取"可复跑命令 + 结果留档"：

```
cd f_util && cjpm test      # WSL Ubuntu-24.04 / x86_64
```

结果（用例数/通过数/失败数）写入 `doc/spec/f-jit-m1/verify.md` 第五轮记录。

## 5. 风险

| 项 | 说明 |
|---|---|
| 哨兵 `-1` 被滥用 | 只有 `noteAbsMem()` 会写入；`auditAllows` 仍拒绝任何真实越界（如 `rax(0)`） |
| `CALL_FUNC` 缺源级触发（方言暂无 `recursive`） | 该路径由审计单测覆盖（哨兵）；源级用例待方言支持后补 |
