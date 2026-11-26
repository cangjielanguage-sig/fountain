# 设计：句柄世代号耗尽与槽位退休

## 背景事实（代码实证）

- `makeId`：`UInt64(gen) << 48 | UInt64(tag) << 32 | UInt32(idx)`（`HandleTable.cj:223`）。
- `gen` 类型为 `UInt16`，`newSlot` 首次分配置 1，每次释放 `+1`（4 处：`releaseConst` /
  `release` / `releaseEscaped` / `resetWindow`），复用时不重置。
- 判空统一为 `id <= 0`；`isLiveHandle` 的注释明确「gen ≥ 1 ⇒ ID ≥ 2^48，与普通整数值域不交」。
- 溢出点：第 32768 次分配同一槽时 `gen = 0x8000`，拼装值 ≥ `2^63`。仓颉的 `Int64(UInt64)` 是受检转换，
  实测抛 `OverflowException`（`HandleTable.cj:227`）；若改为非受检位转换则得到负 ID，被 `id <= 0` 当空句柄。
  两条路径都破坏「标识恒正」这一全库依赖的不变量。

## D1 方案选择

| 方案 | 做法 | 代价 | 结论 |
| --- | --- | --- | --- |
| A. gen 上限 0x7FFF + 槽退休 | 到上限不再 +1、不归还空闲表 | 每 32767 次复用多占 1 槽；标识恒正 | **采纳** |
| B. 判空改 `id == 0` | 允许负 ID | 需改 `idxOf/tagOf/genOf/isLiveHandle/PromotionGroup` 全部判据；`isLiveHandle` 失去「正整数快速拒绝」；任意负数 Int64 会进入掩码解析路径，故障面扩大到所有宿主整数 | 否决（风险/收益不匹配） |
| C. gen 回绕到 1 | 继续复用 | 旧标识在 32767 代后重新可达，违反「释放后旧标识 SHALL 失效」 | 否决 |
| D. 改位域布局（idx 31 位、gen 47–62） | 上限翻倍到 65535 | 需同步 `makeId/idxOf/tagOf/genOf` 与 README 编码说明；只把问题推远一倍 | 暂不做，记为后续余量 |

选 A：**不改变任何既有不变量**（ID 恒正、gen ≥ 1、idx 32 位），只补上溢出的处置分支。

## D2 退休的账目与上限

- 退休槽：`alive=false`、`gens` 停在 `0x7FFF`、不进 `freeSlots`；`totalSlots` 不回退。
- 退休率：单槽每 32767 次复用退休 1 个槽 ⇒ 分摊到每次分配约 **3e-5 槽/次**。
- 表上限：`MAX_SEGS(4096) × SEG_SIZE(1024) = 4M` 槽；`capacityLimit` 默认 1M。
  即使全部槽都走退休路径，可支撑约 `1M × 32767 ≈ 3.4e10` 次分配（1M 次/秒下约 9.3 小时）；
  这是**既有容量上限**的量级，不是本次改动引入的新约束，已记入风险。
- `resetForTest` 复位退休计数；段内容清零时 `gens=0`，与现有行为一致。

## D3 实现

```text
GEN_MAX = 0x7FFF

// 调用方必须持有 mtx
freeOrRetireLocked(seg, off, i):
    if seg.gens[off] >= GEN_MAX:
        retiredSlots += 1
        return                      // 保持 dead，不进 freeSlots
    seg.gens[off] += 1
    freeSlots.add(i)
```

四处释放点统一调用该辅助函数（释放前已把 `alive/objs/escape/frozen` 复位）。

## D4 诊断

`retiredCount(): Int64`（锁内读 `retiredSlots`）：用例据此断言「恰好在第 32767 次复用后退休」，
避免用 `slotCount` 的间接推断（后者还受其它分配影响）。

## D5 TDD 与验证策略

1. **Red 先行**：用例只用**当前已存在**的 API（`pin`/`release`/`getAny`/`isLiveHandle`/`slotCount`），
   断言每次返回的 ID 为正且可读 —— 旧实现第 32768 次必然红（断言失败，非编译错误）。
2. 实现后 Green；再补「退休计数 = 1、`slotCount` 恰增 1、旧 ID 永久失效」三条断言。
3. **变异验证**：临时去掉退休分支（无条件 `+1` 并归还空闲表），Red 用例必须重新变红。
4. 窗口去重会在 `pin` 内扫本窗口清单，用例每轮 `openWindow`/`resetWindow` 保证清单不增长，
   避免 O(n²)。

## 风险

| 风险 | 处置 |
| --- | --- |
| 退休导致 `totalSlots` 单向增长 | 分摊 3e-5 槽/次；达到 `capacityLimit` 仍按既有 16 失败，属既有上限 |
| 旧实现已在生产产生负 ID 句柄 | 负 ID 一律被当空句柄，行为与「已失效」一致；本次不引入兼容层 |
| `gen` 到 `0x7FFF` 的槽被误认为「可达」 | `alive=false` 且不在空闲表，`isLiveHandle` 走 `alive` 判定，不可达 |
