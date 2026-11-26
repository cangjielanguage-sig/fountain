# Design

## 1. 分组

- `leafUnit = stemUnit / 10^leafDigits`。
- `stem = floor(value / stemUnit)`。
- `leaf = round((value - stem * stemUnit) / leafUnit)`，并钳制到 `[0, 10^leafDigits - 1]`。
- 数据排序后逐值分组，行按茎升序、叶天然升序。

## 2. 绘制

- 顶部标题与表头「茎 | 叶」。
- 每行：茎右对齐、`|` 分隔、叶串左对齐，行高 `fontSize + 8`。
- 行 class `stem-leaf-row`，叶串 class `stem-leaf-leaves`。

## 3. 校验

数据为空、非数值、参数越界均抛 `InvalidValue`；仅接受 1 个系列。
