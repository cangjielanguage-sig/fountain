# Spec Delta

## Purpose

为 `f_util` 提供标准 FNV 哈希族（32/64/128/256 位 × fnv1/fnv1a），作为 f_jit 常量指纹与编译去重键的唯一哈希来源，避免模块内自造哈希算法。

## ADDED Requirements

### Requirement: FNV 哈希族全宽可用

`f_util` SHALL 提供 `Fnv32`/`Fnv64`/`Fnv128`/`Fnv256` 四个哈希入口，每个 SHALL 同时支持 `fnv1` 与 `fnv1a` 两种变体，且只使用标准 FNV 偏移基值与素数，禁止自定义常数。

#### Scenario: 空串黄金值

- **WHEN** 对空输入分别计算 `Fnv32.fnv1a`、`Fnv64.fnv1a`、`Fnv128.fnv1a`、`Fnv256.fnv1a`
- **THEN** 结果分别等于标准 FNV 偏移基值 `0x811C9DC5`、`0xCBF29CE484222325`、`0x6C62272E07BB014262B821756295C58D`、`0xDD268DBCAAC550362D98C384C4E576CCC8B1536847B6BBB31023B4C8CAEE0535`

#### Scenario: FNV-1a-64 已知向量

- **WHEN** 计算 `Fnv64.fnv1a("123456789")`
- **THEN** 结果等于 `0x06D5573923C6CDFC`

#### Scenario: fnv1 与 fnv1a 变体可区分

- **WHEN** 对同一非空输入分别调用 `fnv1` 与 `fnv1a`
- **THEN** 两者结果不同，且各自与标准 FNV 参考实现逐位一致

### Requirement: 返回类型与仓库既有类型对齐

`Fnv32` SHALL 返回 `UInt32`，`Fnv64` SHALL 返回 `UInt64`，`Fnv128` SHALL 复用 `f_util.UInt128`，`Fnv256` SHALL 以 4 个 `UInt64` 字（大端序）的数组返回，因为仓库当前没有 256 位标量类型。

#### Scenario: 128 位结果可直接比较与文本化

- **WHEN** 取得 `Fnv128.fnv1a` 的结果
- **THEN** 该结果是 `UInt128`，可直接参与相等比较、`ToString` 与哈希容器键

#### Scenario: 256 位结果字序确定

- **WHEN** 取得 `Fnv256.fnv1a` 的结果并按字展开
- **THEN** 得到长度 4 的 `UInt64` 数组，最高有效字在前（大端序），同一输入两次调用逐位相等

### Requirement: 字节流与字符串输入等价

每个哈希入口 SHALL 同时接受字符串与 `Array<UInt8>` 字节流输入，且对同一内容的两种输入形式产生逐位相同的摘要。

#### Scenario: 字符串与字节流一致

- **WHEN** 对同一段 UTF-8 文本分别以 `String` 与 `Array<UInt8>` 形式计算 `Fnv64.fnv1a`
- **THEN** 两次结果逐位相同

#### Scenario: 增量喂入与一次性喂入一致

- **WHEN** 把一段字节流拆成三段增量喂入同一个哈希上下文
- **THEN** 结果与一次性喂入整段字节流的结果逐位相同，且空增量不改变结果

### Requirement: 4 字节码点与超长输入正确性

哈希实现 SHALL 按字节处理输入，不依赖字符边界与主机端序。

#### Scenario: 多字节码点

- **WHEN** 对含 4 字节码点的字符串（如 emoji）计算 `Fnv64.fnv1a`
- **THEN** 结果与对该串 UTF-8 字节序列的参考实现结果逐位相同

#### Scenario: 长输入不分块失真

- **WHEN** 对长度超过 4 KiB 的输入计算摘要，并与分块增量喂入的结果对照
- **THEN** 两者逐位相同

### Requirement: 黄金值单元测试随实现交付

`Fnv` 的实现 SHALL 附带 `Fnv_test` 单元测试，覆盖各宽度 × 各变体的空串基值、已知向量与增量等价，测试 SHALL 在 `cjpm test` 下全绿。

#### Scenario: 测试覆盖断言

- **WHEN** 在 `f_util` 下运行单元测试
- **THEN** `Fnv_test` 中 32/64/128/256 × fnv1/fnv1a 全部用例通过，且至少包含空串与 `123456789` 两组黄金值
