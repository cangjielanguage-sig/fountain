# 测试计划

本次不改实现，只验证「双载重等价」这条契约仍成立。

| 用例 | 断言 |
| --- | --- |
| `AnyBridgeCall_test.a3_4_callOverloadsAgree` | `call(args, CallContext())` 与 `call(args)` 的正常值、错误码、site 逐位相同 |
| `JitBacked_test.defaultCtorAndCallOverload` | `Compiler()` 无参构造可用；两条 `call` 重载都返回正确值且单元仍是 JIT-backed |

门槛：两文件全绿 + 全量零失败。
