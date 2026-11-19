# Design：对象生命周期加固

## 1. G1 —— 返回值句柄的异常安全

现状（`JitFunction.cj:443-445`）：

```cangjie
let v = marshal.makeRetUnboxer(unboxCode)(ret)     // 可能 contractFail 抛异常
let _ = JitFunction.releaseReturnHandle(ret, ...)  // 异常时跳过
```

`ret` 在解包前已被 `escapeAndGetTyped` 打上逃逸标（`CallMarshal.cj:203-210`），而 `resetWindow`
跳过逃逸槽（`HandleTable.cj:851`）⇒ **每次契约失败泄漏 1 槽**。

修复：解包包 `try/catch`，异常路径先 `releaseReturnHandle` 再 `throw e`；正常路径保持原位。

## 2. G4 —— 句柄返回码单点派生

`isReturnedHandle` 现为硬编码（`JitFunction.cj:491-496`）：

```cangjie
let hosted = unboxCode >= STRING && unboxCode <= HOST_OBJECT && unboxCode != CLOSURE
hosted || unboxCode == ANY || (unboxCode >= JSON_VALUE && unboxCode <= JSON_NULL)
```

改为 `LocalType.isHandle(code) && code != LocalType.CLOSURE`（`LocalType.isHandle` = `4..19`，
`LocalType.cj:125`）。两者等价（`4..11, 13..19`），但新码自动覆盖。

## 3. G5 —— 发射审计（双后端）

- **采集点**：只记**实际发生的内存访问**——
  - x86：`movQwordCtx`(r15)、`movRaxMemRsp`/`leaRdxRsp`/`pushMemRsp`/`moveRaxToMemRsp`/`ucomisdRM`(rsp)、
    `pushMemRbp`/`popMemRbp`(rbp)；
  - a64：`A64Emitter.ldrOff`/`strOff` 的 `rn`。
- **自检**：`X86Lower.lower`/`A64Lower.lower` 结束时校验集合；越界 ⇒ `ok=false`（整单元退回解释器）。
- **允许集**：x86 `{4,5,15}`、a64 `{19,20,29,31}`。这条约束等价于"机器码不得用 helper 返回的
  `cell` 当指针解引用"——因为任何解引用都必须有基址寄存器，而合法基址只有栈/帧/ctx。
- **零产物影响**：审计只在降低期写入静态表，不发一个字节。

## 4. G6 —— 调用级资源归零

用现成 API：`HandleTable.liveCount()`（`HandleTable.cj:949`）、`windowUsed()`（`:236`）、
`NativeMem.outstanding()`（`JitContext.cj:36`）。用例覆盖三类出口各 N 次：

1. 成功调用；
2. 运行期错误（如 1/0 → `DIV_ZERO`）；
3. 契约失败（返回 14、`call<String>`）。

每轮结束断言：`liveCount() == 基线`、`windowUsed() == 0`、`NativeMem.outstanding()` 不增长。

## 5. G3 —— 结论固化（不改语义）

容器写入即 `cellToAny`（`getAny`）⇒ 元素是宿主引用，随容器存活。新增用例：
逃逸闭包捕获 `List`，跨调用读元素仍正确（若元素是句柄则会读到 6/8）。该用例防止将来把容器改成
"存 cell" 时无声破坏 §14.6。

## 6. 风险

| 项 | 说明 |
|---|---|
| 审计误报 | 只在我们自己的发射器里 `note`，模板字节（序言/尾声/收敛块）不采集；若将来新增发射器需同步加 `note` |
| G1 双释放 | `releaseReturnHandle` 幂等（`releaseEscaped` 校验 `alive/gen`），异常路径重复调用安全 |
| G4 等价性 | 新增"码表完备性"用例锁死 0–19 的判定集合 |
