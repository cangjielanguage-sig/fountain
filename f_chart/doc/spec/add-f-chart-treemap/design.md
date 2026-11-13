# Design

## 1. 树构建

- 按 id 建立节点，校验 id 唯一与 parent 存在。
- 恰好一个根（parent 为空）；否则抛 `InvalidValue`。
- 叶子必须有正 value；内部节点值递归求和。

## 2. 布局

- 子节点按值降序，沿较长边按比例切分。
- 递归直到叶子；叶子绘制填充矩形，class `treemap-cell`。
- 颜色按系列/深度轮转，白色描边分隔。

## 3. 标签

叶子名称居中显示，class `treemap-label`。
