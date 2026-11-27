# 设计：编译路径并发优化

## D1 M0：进程内测量（无 strace）

构建机无 `strace`（已确认），只能在进程内计数：

- 临时在 `CodeBuffer.alloc`（`mmap`）与 `seal`（`mprotect`）加静态计数与纳秒累加，
  提供 `CodeBuffer.statsSnapshot()/resetStats()`（**测量后删除**，不合并）；
- 探针编译 12 段不同源码，读取：`mmapCount` / `mmapNs` / `mprotectCount` / `mprotectNs` / `bytes`；
- 与同批 `Compiler.compile` 总耗时对比，得到占比；再跑 4 线程重复一次看占比是否放大。

判定：`mmap+mprotect` 占单次编译 ≥15%（或 4 线程 ≥25%）⇒ C3 立项；否则 C3 不做。

## D2 C1：`awaitReady` 指数退避

现状：

```text
while (spins < 5000000) {
    done = synchronized(mtx) { !compiling.contains(key) }
    if (done) { return synchronized(mtx) { ready.get(key) } }
    spins += 1
}
```

问题：每轮取全局锁，等待者以数百万次/秒的频率抢占 `CompileCache.mtx`。

改法：

```text
deadline = now + 30s
backoff = 64
while (now < deadline) {
    done = synchronized(mtx) { !compiling.contains(key) }
    if (done) { return lookup(key) }
    k = 0
    while (k < backoff) { k += 1 }          // 纯 CPU 空转，不碰锁
    backoff = min(backoff * 2, 8192)
}
None
```

- 不依赖已废弃的 `Monitor` / `ConditionID`；
- 最坏等待粒度 = 8192 次空转（数十 µs），远小于一次编译（0.4–0.9 ms）；
- 预算改成墙钟，避免「快机器上 5M 次过早超时、慢机器上过久」的量纲问题；
- `claim/finish/fail/remove` 语义不变。

## D3 C2：`Compiler.snapshot()` 缓存

- `Compiler` 增加 `private var snapCache: ?PredefinedSnapshot`；
- `snapshot()`：命中即返回；未命中在 `mtx` 内构造并缓存；
- 所有注册/注销入口（`registerFunction` / `unregisterFunction` / `registerClass` /
  `registerType` / `registerInterface`）在 `mtx` 内置 `snapCache = None`；
- 语义：同一线程「注册 → 编译」必然看到新注册（注册先失效、编译再重建）；
- 风险：并发「注册 + 编译」时编译可能用旧快照 —— 与现状（注册不影响已编译产物）一致。

## D4 C3：代码缓冲池化（条件项）

M0 达标才做。候选按收益/风险排序：

1. **页池**：一次 `mmap` 大块（如 1 MiB），按单元切片；`mprotect` 按 64 KiB 页批量切换；
2. **缓冲复用**：`JitFunction.close()` 归还（前提：`active==0` 已排空，P5 已保证），
   新编译优先复用同尺寸块；
3. 尺寸分级（小单元为主）。

必须先定：
- W^X 切换的最小粒度与「写入后封存」顺序（禁止可写可执行同时存在）；
- 归还后的清零（防止旧代码残留被误执行）；
- `munmap` 时机（进程退出 / 池上限）。

## D5 验证

- 每项前后 5 次、中位数 + 最好值；MOV = `max(3%, 2×离散度)`；
- 探针：4 线程 × 6 段不同源码（唯一 seed）；另测「同 key 并发」正确性（1 次管线、同实例）；
- 全量 `cjpm test --parallel 1` 零失败。
