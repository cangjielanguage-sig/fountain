## ADDED Requirements

### Requirement: 句柄世代号上限与槽位退休

句柄标识 SHALL 恒为正数：世代号上限 SHALL 取 `0x7FFF`（最高位留给符号位）。到达上限的槽 SHALL 退休 —— 保持失效、不再进入空闲表、永不复用；退休 SHALL NOT 影响在飞句柄、窗口记账与提升语义。表 SHALL 提供退休槽计数供审计。退休开销 SHALL 至多每槽每 32767 次复用一个槽位，`totalSlots` SHALL NOT 因退休而回退。

#### Scenario: 复用至上限仍为正且可读

- **WHEN** 同一槽被反复分配与释放，直至世代号到达 `0x7FFF`（第 32767 次复用）
- **THEN** 每一次分配返回的标识均为正数，`isLiveHandle` 为真，`getAny` 可读回原值

#### Scenario: 耗尽后退休并分配新槽

- **WHEN** 已到上限的槽被再次释放，随后再分配一个句柄
- **THEN** 该槽不再进入空闲表（退休计数 +1，`slotCount` 恰增 1），新句柄落在表尾的新槽且标识为正

#### Scenario: 退休槽的旧标识永久失效

- **WHEN** 使用退休前最后一个标识读取、判活或显式释放
- **THEN** 读取为空、`isLiveHandle` 为假，释放不改变任何活槽的存活状态
