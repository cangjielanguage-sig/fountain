# svg-rasterization

## ADDED Requirements

### Requirement: M5 混合模式像素合成

系统 SHALL 提供按 `SvgMixBlendMode` 对目标像素与源像素逐像素合成的能力，输入与输出 SHALL 为预乘 RGBA，最终写入 `SvgBitmap` 前转换回非预乘 RGBA8。

合成 SHALL 为：由预乘值还原非预乘颜色 `Cs`、`Cb`；按模式计算可分离混合函数 `B(Cb, Cs)`；按 `Co = (1-αb)·αs·Cs + αb·αs·B(Cb,Cs) + (1-αs)·αb·Cb` 与 `αo = αs + αb·(1-αs)` 得到预乘结果。所有通道 SHALL 钳制到 `0..1`，`αb = 0` 时 SHALL 等于 source-over，`αs = 0` 时 SHALL 保持目标不变。

同一输入、同一模式的重复合成 SHALL 逐字节一致；混合 SHALL NOT 读取目标之外的像素。

#### Scenario: normal 等价

- **WHEN** 同一组源与目标分别用 `normal` 与既有 source-over 合成
- **THEN** 结果逐字节相同

#### Scenario: 零点 alpha

- **WHEN** 目标 alpha 为 0，源为半透明红，模式 `multiply`
- **THEN** 结果为该半透明红，与 source-over 相同

#### Scenario: 源全透明

- **WHEN** 源像素 alpha 为 0，目标为不透明蓝
- **THEN** 目标像素不变

#### Scenario: 钳制

- **WHEN** `color-dodge` 的公式产生超过 1 的通道值
- **THEN** 该通道钳制为 1，其余通道不受影响

#### Scenario: 确定性

- **WHEN** 对同一 8×8 图层连续执行两次 `screen` 合成
- **THEN** 两次位图字节完全相等
