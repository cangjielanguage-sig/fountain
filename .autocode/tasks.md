# f_store 源码审查优化计划

> 已完成：全面审查所有生产源码 + 3 项修复已实施

## ✅ P2 — 空 BloomFilter 缓冲区（已修复）

- `openFromFile()` 中 `bloom_size == 0` 时不再传空数组给 `deserialize`
- 已修复：`SSTable.cj:401-405`，空时 `BloomFilter.new(0, 0.01)` 兜底

## ✅ P3 — Store.get() 冗余 DateTime.now()（已修复）

- `LevelManager` 增加 `get(key, now)` 重载，复用调用方的 `now` 值
- 已修复：`LevelManager.cj:66-76` + `Store.cj:168`

## ✅ P3 — SSTable 序列号范围持久化（已修复）

- Footer 从 48 字节扩展为 64 字节，写入 `sequenceStart` + `sequenceEnd`
- 已修复：`SSTable.cj` Footer 格式、`writeFooter()`、`openFromFile()`
- **注意**：格式变更后旧 `.sst` 文件不兼容，测试前需清理 `/tmp` 下的旧文件
