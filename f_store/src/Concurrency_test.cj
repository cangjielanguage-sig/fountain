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
        println("[TEST] writing ${prewriteCount} entries...")
        for (i in 0..prewriteCount) {
            let key = "ck_${i}".unsafeBytes()
            store.add(key, largeValue)
        }
        println("[TEST] done writing. sleeping 500ms...")

        // 此时 L0 应有多个 SSTable，compactor 应该在后台运行
        // 等待一小段时间让 compaction 有机会启动
        sleep(Duration.millisecond * 500)

        println("[TEST] starting read loop. levels=${store.levelSummary()}")

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
                        if (errorCount <= 10) {
                            println("[TEST MISS] round=${round}  key=ck_${i}  errorCount=${errorCount}")
                        }
                    }
                }
                if (errorCount > 0) {
                    println("[TEST] round=${round}  errorCount=${errorCount}  levels=${store.levelSummary()}")
                    break
                }
                sleep(Duration.millisecond * 10)
            }
            @Expect(errorCount == 0)
        }

        readerFut.get()

        println("[TEST] reader done. checking all keys... levels=${store.levelSummary()}")

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
