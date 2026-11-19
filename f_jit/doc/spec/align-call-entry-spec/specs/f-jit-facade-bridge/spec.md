## MODIFIED Requirements

### Requirement: 调用入口与选项

`call<T>(args, options: CallContext)` SHALL 为带选项入口；`call<T>(args)` SHALL 等价于 `call<T>(args, CallContext())`——两者 SHALL 为**同名重载**，SHALL NOT 另立 `invoke` 入口。SHALL NOT 引入 `tryInvoke`：错误语义与 `call` 完全一致（>0 抛 `JitException`、−2 抛 `InterruptedException`）。

`options.deadline` SHALL 在调用开始前换算为绝对时刻写入运行期，并在 `finally` 恢复调用前的值（重入安全）；`None` SHALL 表示无期限。`CallContext` SHALL 只承载**调用级**选项；编译期策略（产物版本、严格浮点）SHALL NOT 出现在其中。`callForFn<Fn>` SHALL 与 `call` 一样串行化：整段（调用 + 取提升组 + 构造包装）在本单元调用锁内完成，`lastClosureGroup` SHALL NOT 跨调用残留。

#### Scenario: 两入口三态一致

- **WHEN** 分别用 `call(args)` 与 `call(args, CallContext())` 调用同一单元的正常值、>0 错误码、−2 三条出口
- **THEN** 结果、错误码与 site 逐位相同

#### Scenario: lastClosureGroup 不残留

- **WHEN** 连续两次 `callForFn`（两次之间不 close）
- **THEN** 第二次取到的提升组与第一次互不相同，且第一次的包装仍可调用
