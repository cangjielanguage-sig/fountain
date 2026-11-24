# svg-rasterization

## ADDED Requirements

### Requirement: 解析覆盖率累加缓冲的分档

解析覆盖率光栅化 SHALL 按输出像素数选择浮点累加缓冲 `accumulated` 的分配方式：

- 当 `width × height × 8` 字节不超过 **8 MiB**（像素数 ≤ 1,048,576）且宽高均为正时，`accumulated` SHALL 使用 local 分配（`@ local!`），在当前函数返回时随 local region 整体释放；
- 超过该门限、或宽高非正时，`accumulated` SHALL 使用普通堆分配，不得进入 local 分配；
- 每行事件列表 `events` SHALL 使用 local 分配（`@ local!`）；SDK 缺少 `ArrayList<T> @ local?` 的变更重载，档位无法切换，详见 design D3。

门限判定 SHALL 使用除法形式比较（如 `width <= maxElements / height`），不得先计算 `width × height`，以免在极端尺寸下溢出。

门限值与判定结果 SHALL 可被同包测试直接查询，不得依赖渲染整幅大图来观察。

#### Scenario: 门限以下走 local

- **WHEN** 渲染尺寸为 512×512（累加器 2 MiB）
- **THEN** 累加缓冲使用 local 分配，且渲染结果与普通分配逐像素一致

#### Scenario: 恰好等于门限

- **WHEN** 渲染尺寸为 1024×1024 或 2048×512（累加器恰为 8 MiB）
- **THEN** 累加缓冲使用 local 分配

#### Scenario: 超过门限走堆

- **WHEN** 渲染尺寸为 1024×1025（累加器 8 MiB + 8 KiB）、2048×2048（32 MiB），或 3840×2160（约 63 MiB）
- **THEN** 累加缓冲使用普通堆分配，不占用 local region

#### Scenario: 非法尺寸

- **WHEN** `width` 或 `height` 为 0 或负数
- **THEN** 门限判定返回不走 local；`0` 尺寸继续返回空覆盖率，负数尺寸保持既有异常行为，均不因分档而改变

#### Scenario: 极端尺寸不溢出

- **WHEN** 判定宽度为 `Int64` 上限、高度为 2
- **THEN** 判定返回不走 local，且不发生整数溢出或异常

### Requirement: 分档不改变输出

解析覆盖率的 local / 堆分档 SHALL 只影响分配位置，不得改变任何可观察输出：同一轮廓、同一 `fillRule`、同一尺寸下，两条路径产生的覆盖率数组 SHALL 逐元素相等；既有渲染快照 SHALL 逐字节不变。

#### Scenario: 单轮廓等价

- **WHEN** 同一三角形轮廓分别以 local 档位与堆档位计算覆盖率（nonzero）
- **THEN** 两个数组长度相同且每个元素相等

#### Scenario: 多轮廓与 evenodd 等价

- **WHEN** 甜甜圈（多轮廓 evenodd）与自交五角星（nonzero / evenodd）分别以两种档位计算
- **THEN** 对应数组逐元素相等，且与既有 64× 参考图的误差界限不变

#### Scenario: 既有快照回归

- **WHEN** 运行 `f_svg` 既有渲染快照用例与全部解析覆盖率用例
- **THEN** 输出逐字节一致，无新增失败

#### Scenario: 重复渲染确定

- **WHEN** 同一文档以 `antiAlias = Analytic` 连续渲染两次
- **THEN** 两次输出的像素数组完全相同
