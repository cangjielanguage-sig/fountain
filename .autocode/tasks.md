# fsync 模块静态诊断报告 — 第 2 轮

审查范围：`fsync/src/` 全部 12 个源文件（不含测试/基准）
审查日期：2026-05-04
审查方式：静态代码分析

**前次诊断结果**：3×P0 + 4×P1 + 2×P2 + 5×P3 全部处理完毕。
**本轮发现**：2 个新 P3 问题。

---

## [P3] NodeManager 健康检查 spawn 缺少异常保护

- **问题等级**: P3
- **问题描述**: `NodeManager.cj:42` — `spawn { while(true) { sleep(5s); ...; aliveRef.store(count) } }` 没有 try-catch 包裹。如果 `pingNode()` 抛出未被捕获的异常（如内存不足），整个健康检查线程无声退出。
- **触发条件**: `pingNode()` 意外的异常
- **改进方案**: 在 while 体外套 try-catch，捕获所有异常以防线程崩溃：
  ```cj
  spawn {
      while (true) {
          try {
              sleep(Duration.second * 5)
              var count = 1i64
              for (node in others) {
                  if (pingNode(node.host, node.port)) { count++ }
              }
              aliveRef.store(count)
          } catch (_: Exception) {}
      }
  }
  ```
- **实施难度**: 低

## [P3] SyncClient.prefix/glob 代码重复

- **问题等级**: P3
- **问题描述**: `SyncClient.cj:110-119` 和 `123-132` — `prefix()` 与 `glob()` 的完整函数体（8 行）完全相同。此前 `glob()` 委托给 `prefix()`，重构为独立实现后引入了重复。
- **触发条件**: 任何对 prefix/glob 的修改需要同步修改两处
- **改进方案**: 提取私有辅助方法 `scan(pattern: String): ScanResult`：
  ```cj
  private func scan(pattern: String): ScanResult {
      requireAbsolutePath(pattern)
      let req = Message(Command.ACK, PatternData(pattern).toData())
      if (let Some(resp) <- client.transfer(req.id, req, requestTimeout) &&
          let Some(vd) <- convert<ValueData>(resp.data) &&
          let Some(blob) <- vd.value) {
          return ScanResult.decodeFromBytes(blob)
      }
      ScanResult()
  }
  ```
  然后 `prefix(pattern) = scan(pattern)`，`glob(pattern) = scan(pattern)`。
- **实施难度**: 低

---

## 已确认无问题的检查项

| 检查项 | 结论 |
|--------|------|
| TODO/FIXME | 0 处 |
| 空函数体 | 仅 DataAssist 必需的 init() |
| Resource close | SyncServer + WatchManager 均正确 |
| while(true) | NodeManager 健康检查 + SyncCommand 主线程（已确认保留） |
| spawn 异常 | 4/5 有 try-catch，仅 NodeManager 一处缺 |
| 锁顺序 | 所有类使用单 Mutex，无嵌套锁 |
| None 解引用 | 2 处 getOrThrow() 均有守卫条件 |
| 字符串拼接热点 | 无（HashRing 构造器单次执行） |
| 未使用 import | 4 处候选，无可见影响 |
