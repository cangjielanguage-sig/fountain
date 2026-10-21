## MODIFIED Requirements

### Requirement: 编译选项的版本与严格浮点

`CompileOptions.verMajor` SHALL 决定源码产物的字节码主版本，缺省为 `Version.LATEST`；不受支持的值 SHALL 在 `compile` 时以 `SourceCompileException` 拒绝，SHALL NOT 落到运行期错误槽。

`CompileOptions.strictFp` SHALL 决定 `Float64` 的 `/` 的发射形态：`false` → `FDIV`（÷0 得 ±Inf，IEEE）；`true` → `FDIV_CHK`（÷0 → 错误码 1）。**该选项缺省 SHALL 为 `true`**——需要 IEEE 语义的调用方 SHALL 显式关闭。缓存键 SHALL 同时包含主版本与严格浮点标记，同源不同配置 SHALL 产出独立单元。

`CallContext` SHALL NOT 包含 `literalCopy`：字面量是编译期常量，桥层不存在「深拷贝字面量」的时机，该字段自始无消费点。

#### Scenario: 版本选项生效

- **WHEN** 以 `verMajor = Version.M2_MAJOR` 编译一段含 `Any` 的源码
- **THEN** `compile` 抛 `SourceCompileException`（局部槽类型码 15 非法）；改用 `Version.LATEST` 后编译通过

#### Scenario: 缺省即严格

- **WHEN** 不设置 `strictFp` 编译 `{ x: Float64 => 1.0 / x }` 并以 `x = 0.0` 调用
- **THEN** 以 1（`DIV_ZERO`）失败；产物里的除法 opcode 为 `FDIV_CHK`

#### Scenario: 严格浮点开与关

- **WHEN** 分别以 `strictFp = false` 与 `true` 编译 `{ x: Float64 => 1.0 / x }` 并按 `x = 0.0` 调用
- **THEN** 前者返回 `+Inf`（错误码 0）；后者以 1（`DIV_ZERO`）失败；两者产物里的除法 opcode 分别为 `FDIV` 与 `FDIV_CHK`

#### Scenario: 同源不同配置不串缓存

- **WHEN** 同一源码先用 `strictFp = false` 编译，再用 `true` 编译
- **THEN** 得到两个不同单元，各自的除法 opcode 与调用行为互不影响
