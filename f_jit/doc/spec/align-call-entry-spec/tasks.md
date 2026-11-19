# Tasks

## E1 规格对齐

- [x] E1.1 修改 `调用入口与选项`：入口名 `invoke` → `call` 重载，保留「不引入 `tryInvoke`」与 `CallContext` 只装调用级选项的条款；两条既有 Scenario 全部保留。**（`两入口三态一致` 的 WHEN 改为 `call(args)` 与 `call(args, CallContext())`）**
- [x] E1.2 `validate --strict` 通过。**（Change is valid）**

## E2 用例口径

- [x] E2.1 `AnyBridgeCall_test.a3_4_invokeMatchesCall` 改名 `a3_4_callOverloadsAgree`，注释与局部变量去掉 `invoke`。**（另同步 `JitValue` / `ValueTypes_test` / `JitFunction` 的注释口径）**
- [x] E2.2 断言不变（正常值等价、÷0 错误码与 site 一致）；`JitBacked_test.defaultCtorAndCallOverload` 保持。**（7/7、4/4 全绿）**

## E3 验证与归档

- [x] E3.1 跑 `AnyBridgeCall_test` 与 `JitBacked_test`，全绿
- [x] E3.2 全量回归零失败。**（1114/1115，唯一失败为 `PerfM2_test` 负载假失败，单跑通过）**
- [x] E3.3 归档 `openspec archive align-call-entry-spec --yes`（+0 added / ~1 modified），同步 `f_jit/doc/spec/` 镜像
