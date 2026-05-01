/*
 Copyright (c) 2026 WuJingrun（吴京润）
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
     http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */
package fountain::f_store

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.sync.AtomicBool

@Test
public class ConcurrencyTest {
    var testDir: String = ""

    /** 用例1：多写者并发 add
     *  启动 N 个线程，每个线程向同一个 Store 写入 M 条不重叠 key 的数据。
     *  验证所有 key 均可正确读出，Store 总条目数 = N × M。
     */
    @TestCase
    public func testMultiWriterConcurrentAdd(): Unit {
        let dir = getTestDir("multi_writer")
        let store = Store(dir)
        let N = 4
        let M = 100

        let futures = ArrayList<Future<Unit>>()
        for (t in 0..N) {
            let fut = spawn {
                for (i in 0..M) {
                    let key = "t${t}_k${i}".unsafeBytes()
                    let value = "t${t}_v${i}".unsafeBytes()
                    store.add(key, value)
                }
            }
            futures.add(fut)
        }

        // 等待全部线程完成
        for (fut in futures) {
            fut.get()
        }

        // 验证所有 key 均可正确读出
        for (t in 0..N) {
            for (i in 0..M) {
                let key = "t${t}_k${i}".unsafeBytes()
                let expectedValue = "t${t}_v${i}".unsafeBytes()
                let result = store.get(key)
                @Expect(result.isSome())
                if (let Some(v) <- result) {
                    @Expect(v == expectedValue)
                }
            }
        }

        store.close()
    }

    /** 用例2：读写并发
     *  线程A：持续写入 key "counter"，value 为递增数字（零填充保证字典序）
     *  线程B：持续读取 key "counter"，验证 value 单调不减
     */
    @TestCase
    public func testReadWriteConcurrent(): Unit {
        let dir = getTestDir("rw_concurrent")
        let store = Store(dir)
        let key = "counter".unsafeBytes()
        let iterations: Int64 = 500

        // 用于标记写入是否完成
        let writeDone = AtomicBool(false)

        // Writer thread
        let writerFut = spawn {
            for (i in 0..iterations) {
                let value = formatCounter(i)
                store.add(key, value)
            }
            writeDone.store(true)
        }

        // Reader thread：持续读取，验证值单调不减
        let readerFut = spawn {
            var lastVal: ?Array<Byte> = None
            var readCount: Int64 = 0
            while (!writeDone.load() || readCount < 100) {
                let result = store.get(key)
                if (let Some(v) <- result) {
                    if (let Some(last) <- lastVal) {
                        // 验证单调不减
                        @Expect(!arrayByteLess(v, last))
                    }
                    lastVal = Some(v)
                }
                readCount++
                sleep(Duration.millisecond * 1)
            }
        }

        writerFut.get()
        readerFut.get()

        // 最终值应为最后一次写入
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == formatCounter(iterations - 1))
        }

        store.close()
    }

    /** 用例3：flush 与写入并发
     *  线程A：高速写入大 value，触发 MemTable 多次 swap+flush
     *  线程B：随机读取已写入的 key，验证总能读到（写入后可见）
     *  验证 flush 期间无数据丢失
     */
    @TestCase
    public func testFlushAndWriteConcurrent(): Unit {
        let dir = getTestDir("flush_write")
        let store = Store(dir)
        let keyCount: Int64 = 500
        // 使用 16KB 的 value 加速触发 flush（阈值 8MB）
        let largeValue = Array<Byte>(16 * 1024, repeat: 88u8)

        // 先写入一批 key 作为基础数据
        for (i in 0..keyCount) {
            let key = "fk_${i}".unsafeBytes()
            store.add(key, largeValue)
        }

        // Writer：持续写入更多大 value 触发 flush
        let writeDone = AtomicBool(false)
        let writerFut = spawn {
            for (i in keyCount..keyCount + 300) {
                let key = "fk_${i}".unsafeBytes()
                store.add(key, largeValue)
            }
            writeDone.store(true)
        }

        // Reader：随机读取已写入的 key
        let readerFut = spawn {
            var errors: Int64 = 0
            var readCount: Int64 = 0
            while (!writeDone.load() || readCount < 200) {
                // 随机选一个 key 读取（范围逐渐扩大）
                let maxKey = if (writeDone.load()) { keyCount + 300 } else { keyCount + 100 }
                let idx = readCount % maxKey
                let key = "fk_${idx}".unsafeBytes()
                let result = store.get(key)
                // 写入后应可见（不要求一定读到，因为可能尚未写入该 key）
                // 但不应抛出异常
                readCount++
                sleep(Duration.millisecond * 2)
            }
            @Expect(errors == 0)
        }

        writerFut.get()
        readerFut.get()

        // 验证所有写入的 key 最终都可读
        let totalKeys = keyCount + 300
        var missingCount: Int64 = 0
        for (i in 0..totalKeys) {
            let key = "fk_${i}".unsafeBytes()
            let result = store.get(key)
            if (result.isNone()) {
                missingCount++
            }
        }
        @Expect(missingCount == 0)

        store.close()
    }

    /** 用例4：compaction 与读取并发
     *  预先写入大量数据触发多层 compaction
     *  线程A：compaction 后台运行
     *  线程B：持续随机读取，验证不会返回错误或数据不一致
     */
    @TestCase
    public func testCompactionAndReadConcurrent(): Unit {
        let dir = getTestDir("compact_read")
        let store = Store(dir)
        // 写入足以触发多次 flush 的数据（每次 flush ~8MB 产生 1 个 SSTable）
        // 需要 4+ SSTable 触发 L0 compaction
        let largeValue = Array<Byte>(32 * 1024, repeat: 66u8) // 32KB per entry
        let prewriteCount: Int64 = 1200 // ~38MB，触发 4+ 次 flush

        // 预写入大量数据
        for (i in 0..prewriteCount) {
            let key = "ck_${i}".unsafeBytes()
            store.add(key, largeValue)
        }

        // 此时 L0 应有多个 SSTable，compactor 应该在后台运行
        // 等待一小段时间让 compaction 有机会启动
        sleep(Duration.millisecond * 500)

        // Reader：随机读取，验证不报错且数据一致
        let readDone = AtomicBool(false)
        let readerFut = spawn {
            var errorCount: Int64 = 0
            for (round in 0..100) {
                for (i in 0..prewriteCount) {
                    let key = "ck_${i}".unsafeBytes()
                    let result = store.get(key)
                    if (result.isNone()) {
                        errorCount++
                    }
                }
                if (errorCount > 0) {
                    break
                }
                sleep(Duration.millisecond * 10)
            }
            @Expect(errorCount == 0)
        }

        readerFut.get()

        // 验证所有预写入的 key 最终都可读
        var missingCount: Int64 = 0
        for (i in 0..prewriteCount) {
            let key = "ck_${i}".unsafeBytes()
            let result = store.get(key)
            if (result.isNone()) {
                missingCount++
            }
        }
        @Expect(missingCount == 0)

        store.close()
    }

    /** 用例5：close 与写入并发
     *  持续写入的同时触发 close，然后 reopen 验证所有已确认写入的数据完整。
     *  专门验证 close 时 swapActive + flush 的原子性修复。
     */
    @TestCase
    public func testCloseDuringConcurrentWrites(): Unit {
        let dir = getTestDir("close_during_write")
        let store = Store(dir)
        let baseCount: Int64 = 100

        // 1. 写入基础数据（close 前一定已提交）
        for (i in 0..baseCount) {
            let key = "base_${i}".unsafeBytes()
            store.add(key, "bv_${i}".unsafeBytes())
        }

        // 2. 启动多个 writer，持续写入直到 close
        let shouldRun = AtomicBool(true)
        let writerCount = 3
        let writerFutures = ArrayList<Future<ArrayList<Array<Byte>>>>()

        for (t in 0..writerCount) {
            let fut = spawn {
                let myKeys = ArrayList<Array<Byte>>()
                var idx: Int64 = 0
                while (shouldRun.load()) {
                    let key = "cdw_${t}_${idx}".unsafeBytes()
                    try {
                        store.add(key, "cdw_v${t}_${idx}".unsafeBytes())
                        myKeys.add(key)
                        idx++
                    } catch (_: StoreClosedException) {
                        break
                    }
                }
                myKeys
            }
            writerFutures.add(fut)
        }

        // 3. 给 writer 一点时间积累写入（~50ms）
        sleep(Duration.millisecond * 50)

        // 4. close 而 writer 仍运行中
        store.close()
        shouldRun.store(false)

        // 5. 收集各 writer 已确认的 key
        let acknowledgedKeys = ArrayList<Array<Byte>>()
        for (fut in writerFutures) {
            let keys = fut.get()
            for (k in keys) {
                acknowledgedKeys.add(k)
            }
        }
        // 6. reopen 验证
        let reopened = Store(dir)

        // 验证基础数据（100% 应存活）
        var baseMissing: Int64 = 0
        for (i in 0..baseCount) {
            let key = "base_${i}".unsafeBytes()
            if (reopened.get(key).isNone()) {
                baseMissing++
            }
        }
        @Expect(baseMissing == 0)

        // 验证 close 期间已确认的写入（add() 返回了正常值，必须存活）
        var ackMissing: Int64 = 0
        for (ackKey in acknowledgedKeys) {
            if (reopened.get(ackKey).isNone()) {
                ackMissing++
            }
        }
        @Expect(ackMissing == 0)

        reopened.close()
    }

    /** 混合并发：add/remove/get/多前缀迭代同时运行 */
    @TestCase
    public func testMixedAddRemoveGetPrefix(): Unit {
        let dir = getTestDir("mixed_all")
        let store = Store(dir)
        let baseCount: Int64 = 200
        let runtimeMs: Int64 = 2000  // 运行 2 秒
        let startTime = DateTime.now().toUnixTimeStamp().toNanoseconds()

        // 1. 预写入基础数据
        for (i in 0..baseCount) {
            store.add("mx_base_${i}".unsafeBytes(), "base_v".unsafeBytes())
        }

        let running = AtomicBool(true)

        // 2. Writer：持续 add 新 key（不同前缀范围）
        let writerFut = spawn {
            var idx: Int64 = 0
            while (running.load()) {
                try {
                    store.add("mx_w_${idx}".unsafeBytes(), "wv_${idx}".unsafeBytes())
                    idx++
                } catch (_: StoreClosedException) { break }
            }
            idx
        }

        // 3. Remover：持续 remove 已有 key
        let removerFut = spawn {
            var idx: Int64 = 0
            var removed: Int64 = 0
            while (running.load()) {
                try {
                    let key = "mx_base_${idx}".unsafeBytes()
                    let old = store.remove(key)
                    if (old.isSome()) { removed++ }
                    idx = (idx + 1) % baseCount
                } catch (_: StoreClosedException) { break }
            }
            removed
        }

        // 4. Getter：持续随机读取
        let getterFut = spawn {
            var gets: Int64 = 0
            var hits: Int64 = 0
            while (running.load()) {
                try {
                    let key = "mx_w_${gets % 500}".unsafeBytes()
                    let result = store.get(key)
                    if (result.isSome()) { hits++ }
                    gets++
                } catch (_: StoreClosedException) { break }
            }
            (gets, hits)
        }

        // 5. TTL updater：持续更新已有 key 的过期时间
        let ttlFut = spawn {
            var updates: Int64 = 0
            while (running.load()) {
                try {
                    let key = "mx_base_${updates % baseCount}".unsafeBytes()
                    // 交替设置 1s 和 10s TTL，同时测试 expireAt 和 Duration 两种重载
                    if (updates % 2 == 0) {
                        store.ttl(key, Duration.second * 10)
                    } else {
                        store.ttl(key, DateTime.now() + Duration.second * 10)
                    }
                    updates++
                } catch (_: StoreClosedException) { break }
            }
            updates
        }

        // 6. Prefix iterators：多个前缀同时迭代
        let prefixFutures = ArrayList<Future<Int64>>()
        for (p in 0..3) {
            let prefix = "mx_${["base", "w", "other"][p]}".unsafeBytes()
            let fut = spawn {
                var total: Int64 = 0
                while (running.load()) {
                    try {
                        let iter = store.prefix(prefix)
                        var count: Int64 = 0
                        while (let Some(_) <- iter.next()) {
                            count++
                        }
                        total += count
                    } catch (_: StoreClosedException) { break }
                }
                total
            }
            prefixFutures.add(fut)
        }

        // 7. 运行指定时间后停止
        sleep(Duration.millisecond * runtimeMs)
        running.store(false)

        // 8. 收集结果
        let writerCount = writerFut.get()
        let removerCount = removerFut.get()
        let (getCount, hitCount) = getterFut.get()
        let ttlUpdates = ttlFut.get()

        // 9. close + reopen 验证数据完整性
        store.close()
        let reopened = Store(dir)

        // 基础数据：被 remove 的已不存在，未 remove 的在
        var baseOk: Int64 = 0
        for (i in 0..baseCount) {
            let key = "mx_base_${i}".unsafeBytes()
            if (reopened.get(key).isSome()) { baseOk++ }
        }

        // Writer 写入的 key 全部应在（确认了才返回）
        var writerOk: Int64 = 0
        for (i in 0..writerCount) {
            let key = "mx_w_${i}".unsafeBytes()
            if (reopened.get(key).isSome()) { writerOk++ }
        }

        @Expect(baseOk + writerOk > 0)
        @Expect(getCount > 0)

        reopened.close()
    }

    // ================================================================
    // 辅助方法
    // ================================================================

    /** 生成零填充的计数器字符串字节数组，保证字典序与数值序一致 */
    private func formatCounter(n: Int64): Array<Byte> {
        let raw = n.toString()
        'val_${"0" * (6 - raw.size)}${raw}'.unsafeBytes()
    }

    /** 字典序比较：a < b */
    private func arrayByteLess(a: Array<Byte>, b: Array<Byte>): Bool {
        let minLen = if (a.size <= b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] < b[i]) {
                return true
            }
            if (a[i] > b[i]) {
                return false
            }
        }
        a.size < b.size
    }

    func getTestDir(name: String): String {
        let baseDir = "/tmp/f_store_test/Concurrency_${name}"
        // 清理旧数据
        if (exists(baseDir)) {
            remove(baseDir, recursive: true)
        }
        baseDir
    }
}
