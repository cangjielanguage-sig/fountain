# Spec Delta

## ADDED Requirements

### Requirement: AArch64 访存立即数的范围判定

`ldr/str` 的 9 位有符号立即数偏移（−256…255）SHALL 在编码前判定范围：界内 SHALL 使用 immediate 形式；界外 SHALL 回退到慢路径（先物化偏移到 scratch 寄存器并与基址相加，再以 0 偏移访存），SHALL NOT 用 `off & 0x1FF` 静默截断。

慢路径 SHALL：不与活跃值争用寄存器；不破坏两遍布局的跳转偏移计算；执行结果与解释器逐位一致。

#### Scenario: 边界值

- **WHEN** 编码偏移 `-256`、`-257`、`255`、`256`
- **THEN** `-256` 与 `255` 走 immediate 形式，`-257` 与 `256` 走慢路径；四者的访存地址均为「基址 + 偏移」

#### Scenario: 结果与解释器一致

- **WHEN** 一个函数包含越界偏移的连续读改写，分别走解释器与 AArch64
- **THEN** 内存最终状态逐位相同

#### Scenario: 前后向跳转仍正确

- **WHEN** 含慢路径的函数存在跨越该序列的前向与后向跳转
- **THEN** 两遍布局算出的目标地址正确（构造性用例各一）
