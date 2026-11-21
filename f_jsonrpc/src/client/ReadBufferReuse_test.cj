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
package fountain::f_jsonrpc.client

import std.collection.{ArrayList, HashSet}
import std.env.getVariable
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.sort.*
import std.sync.{AtomicInt64, Barrier, Mutex}
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*

private const READ_BUFFER_TEST_BYTES: Int64 = 8192

private func fillText(c: UInt8, n: Int64): String {
    String.fromUtf8(Array<Byte>(n, repeat: c))
}

/** 响应头按 ASCII body 的字节数声明 `Content-Length`（本文件的 body 全部为 ASCII）。 */
private func rpcResponse(body: String): String {
    'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\n\r\n${body}'
}

private func fillBuffer(buffer: Array<Byte>, value: UInt8): Unit {
    for (i in 0..buffer.size) {
        buffer[i] = value
    }
}

private func isFilledWith(buffer: Array<Byte>, value: UInt8): Bool {
    for (i in 0..buffer.size) {
        if (buffer[i] != value) {
            return false
        }
    }
    true
}

private func tagOf(seq: Int64): UInt8 {
    UInt8(97 + seq % 26)
}

@Test
class ReadBufferReuse_test {
    /** 同线程连续两次取缓冲必须拿到同一实例（哨兵字节留在缓冲里）。 */
    @TestCase
    public func testReadBufferIsReusedOnSameThread(): Unit {
        let first = HttpJsonRpcTransport.readBuffer()
        fillBuffer(first, 0x5A)
        let second = HttpJsonRpcTransport.readBuffer()
        @Assert(READ_BUFFER_TEST_BYTES, second.size)
        @Assert(UInt8(0x5A), second[0])
        @Assert(UInt8(0x5A), second[READ_BUFFER_TEST_BYTES - 1])
    }

    /** 读路径确实落在当前线程的缓冲上：响应首字节会覆盖缓冲首字节。 */
    @TestCase
    public func testReadCappedUsesThreadBuffer(): Unit {
        let buffer = HttpJsonRpcTransport.readBuffer()
        buffer[0] = 0
        let body = '{"jsonrpc":"2.0","id":1,"result":1}'
        let server = RawHttpServer({sock, w => writeText(sock, rpcResponse(body), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let bytes = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(body, String.fromUtf8(bytes))
        @Assert(UInt8(123), HttpJsonRpcTransport.readBuffer()[0])
    }

    /** 上一轮的残余字节不能进入本次结果：缓冲全部预热为 0xFF 后读 64 B 响应。 */
    @TestCase
    public func testStaleTailDoesNotLeak(): Unit {
        fillBuffer(HttpJsonRpcTransport.readBuffer(), 0xFF)
        let body = fillText(UInt8(97), 64)
        let server = RawHttpServer({sock, w => writeText(sock, rpcResponse(body), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let bytes = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(64, bytes.size)
        @Assert(body, String.fromUtf8(bytes))
    }

    /** 两个线程各自持有独立缓冲：同步后各自整块校验，互不污染。 */
    @TestCase
    public func testReadBufferIsolatedAcrossThreads(): Unit {
        let barrier = Barrier(3)
        let first = spawn {
            let buffer = HttpJsonRpcTransport.readBuffer()
            fillBuffer(buffer, 0xA1)
            barrier.wait()
            isFilledWith(buffer, 0xA1)
        }
        let second = spawn {
            let buffer = HttpJsonRpcTransport.readBuffer()
            fillBuffer(buffer, 0xB2)
            barrier.wait()
            isFilledWith(buffer, 0xB2)
        }
        barrier.wait()
        @Assert(true, first.get())
        @Assert(true, second.get())
    }

    /** 并发多响应：8 线程 × 5 次 `callAsync`，每次约 9 KiB、带唯一序号，结果必须完整不交错。 */
    @TestCase
    public func testConcurrentCallsGetIntactResponses(): Unit {
        let threads: Int64 = 8
        let perThread: Int64 = 5
        let fillerBytes: Int64 = 9000
        let seq = AtomicInt64(0)
        let server = RawHttpServer({sock, w =>
            sleep(Duration.millisecond * 10)
            let n = seq.fetchAdd(1)
            let filler = fillText(tagOf(n), fillerBytes)
            let body = '{"jsonrpc":"2.0","id":1,"result":"${n}|${filler}"}'
            writeText(sock, rpcResponse(body), w)
        })
        let client = JsonRpcClient(server.url, opts: ClientOptions())
        let mutex = Mutex()
        let results = ArrayList<String>()
        let barrier = Barrier(threads + 1)
        let futures = ArrayList<Future<Unit>>()
        for (_ in 0..threads) {
            futures.add(
                spawn {
                    barrier.wait()
                    for (_ in 0..perThread) {
                        let value = client.callAsync('ping').get()
                        let text = match (value) {
                            case s: JsonString => s.value
                            case _ => 'not-a-string'
                        }
                        synchronized(mutex) {
                            results.add(text)
                        }
                    }
                })
        }
        barrier.wait()
        for (f in futures) {
            f.get()
        }
        client.close()
        server.close()
        @Assert(threads * perThread, results.size)
        let seen = HashSet<Int64>()
        for (text in results) {
            let parts = text.split('|')
            @Assert(2, parts.size)
            let n = Int64.parse(parts[0])
            seen.add(n)
            @Assert(fillText(tagOf(n), fillerBytes), parts[1])
        }
        @Assert(threads * perThread, seen.size)
    }

    /** 分块读取：8191 / 8192 / 8193 / 24583 B 各分 4 次写出，返回长度与内容必须精确。 */
    @TestCase
    public func testMultiChunkResponseIsExact(): Unit {
        let lengths = [8191, 8192, 8193, 24583]
        var index = 0
        for (length in lengths) {
            let body = fillText(tagOf(index), length)
            let bytes = body.toArray()
            let step = (length + 3) / 4
            let server = RawHttpServer({sock, w =>
                writeText(sock,
                    'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${length}\r\n\r\n',
                    w)
                var start: Int64 = 0
                while (start < length) {
                    let rawEnd = start + step
                    let end = if (rawEnd > length) {
                        length
                    } else {
                        rawEnd
                    }
                    if (!writeBytes(sock, bytes[start..end], w)) {
                        break
                    }
                    start = end
                }
            })
            let transport = HttpJsonRpcTransport(server.url, ClientOptions())
            let got = transport.send('{}'.unsafeBytes())
            transport.close()
            server.close()
            @Assert(length, got.size)
            @Assert(body, String.fromUtf8(got))
            index++
        }
    }

    /** 小响应回归：64 B 响应长度与内容正确。 */
    @TestCase
    public func testSmallResponseUnaffected(): Unit {
        let body = '{"jsonrpc":"2.0","id":1,"result":"${fillText(UInt8(98), 28)}"}'
        let server = RawHttpServer({sock, w => writeText(sock, rpcResponse(body), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let got = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(body.size, got.size)
        @Assert(body, String.fromUtf8(got))
    }

    /** 返回值不与线程缓冲共享存储：覆写线程缓冲不能改变已返回的数组。 */
    @TestCase
    public func testReturnedBytesAreIndependentOfBuffer(): Unit {
        let body = fillText(UInt8(99), 64)
        let server = RawHttpServer({sock, w => writeText(sock, rpcResponse(body), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let got = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        fillBuffer(HttpJsonRpcTransport.readBuffer(), 0xFF)
        @Assert(body, String.fromUtf8(got))
    }

    /** 门控默认关闭：未设置环境变量时基准走 SKIP，不拖慢常规测试。 */
    @TestCase
    public func testBenchGateDefaultsOff(): Unit {
        if (jsonrpcBenchEnabled()) {
            println("SKIP: F_JSONRPC_BENCH=1，门控用例在开启态不做断言")
            return
        }
        @Assert(!jsonrpcBenchEnabled())
        println("SKIP: 未设置 F_JSONRPC_BENCH=1，读缓冲分配基准不执行")
    }

    /**
     * `case=reuse` / `case=fresh`：读缓冲复用与每次新建的分配对照。
     * 断言只用确定性的分配量（同线程复用 `<= 64 B/次`，且比每次新建低一个数量级以上）；
     * 耗时只打印。
     */
    @TestCase
    public func testBenchReadBufferAllocation(): Unit {
        if (!jsonrpcBenchEnabled()) {
            println("SKIP: 未设置 F_JSONRPC_BENCH=1，读缓冲分配基准不执行")
            return
        }
        let ops: Int64 = 5000
        let sink = AtomicInt64(0)
        // 预热：首块缓冲的 8192 B 不计入摊销窗口
        sink.fetchAdd(Int64(HttpJsonRpcTransport.readBuffer()[0]))
        let (reuseAlloc, reuseNs, reuseSamples) = jsonrpcMeasure({ =>
            for (_ in 0..ops) {
                sink.fetchAdd(Int64(HttpJsonRpcTransport.readBuffer()[0]))
            }
        })
        let (freshAlloc, freshNs, freshSamples) = jsonrpcMeasure({ =>
            for (_ in 0..ops) {
                let buffer = Array<Byte>(READ_BUFFER_TEST_BYTES, repeat: 0)
                sink.fetchAdd(Int64(buffer[0]))
            }
        })
        @Assert(reuseSamples > 0 && freshSamples > 0)
        let reusePerOp = reuseAlloc / ops
        let freshPerOp = freshAlloc / ops
        println('JSONRPC_READBUF_BENCH case=reuse ops=${ops} allocTotal=${reuseAlloc} ' +
            'allocPerOp=${reusePerOp} nsPerOp=${reuseNs / ops} samples=${reuseSamples}')
        println('JSONRPC_READBUF_BENCH case=fresh ops=${ops} allocTotal=${freshAlloc} ' +
            'allocPerOp=${freshPerOp} nsPerOp=${freshNs / ops} samples=${freshSamples}')
        @Assert(reuseAlloc >= 0 && reusePerOp <= 64)
        @Assert(reuseAlloc * 16 < freshAlloc)
    }

    /** `case=send_small` / `case=send_multichunk`：端到端发送的 `allocPerCall` 与耗时，只打印。 */
    @TestCase
    public func testBenchSendAllocation(): Unit {
        if (!jsonrpcBenchEnabled()) {
            println("SKIP: 未设置 F_JSONRPC_BENCH=1，发送分配基准不执行")
            return
        }
        let calls: Int64 = 500
        let sink = AtomicInt64(0)
        let cases = [('send_small', 64), ('send_multichunk', 24583)]
        for ((label, bytes) in cases) {
            let body = fillText(UInt8(100), bytes)
            let server = RawHttpServer({sock, w => writeText(sock, rpcResponse(body), w)})
            let transport = HttpJsonRpcTransport(server.url, ClientOptions())
            let _ = transport.send('{}'.unsafeBytes())
            let (alloc, ns, samples) = jsonrpcMeasure({ =>
                for (_ in 0..calls) {
                    sink.fetchAdd(Int64(transport.send('{}'.unsafeBytes())[0]))
                }
            })
            transport.close()
            server.close()
            @Assert(samples > 0)
            println('JSONRPC_READBUF_BENCH case=${label} ops=${calls} allocTotal=${alloc} ' +
                'allocPerCall=${alloc / calls} nsPerCall=${ns / calls} samples=${samples}')
        }
        @Assert(true, sink.load() >= 0)
    }

    /** `case=send_concurrent`：8 线程 × 250 次串行发送，打印总分配与墙钟吞吐。 */
    @TestCase
    public func testBenchSendConcurrent(): Unit {
        if (!jsonrpcBenchEnabled()) {
            println("SKIP: 未设置 F_JSONRPC_BENCH=1，并发发送基准不执行")
            return
        }
        let threads: Int64 = 8
        let perThread: Int64 = 250
        let ops = threads * perThread
        let body = fillText(UInt8(100), 64)
        let server = RawHttpServer({sock, w => writeText(sock, rpcResponse(body), w)})
        let transports = ArrayList<HttpJsonRpcTransport>()
        for (_ in 0..threads) {
            transports.add(HttpJsonRpcTransport(server.url, ClientOptions()))
        }
        let sink = AtomicInt64(0)
        let barrier = Barrier(threads + 1)
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..threads) {
            let transport = transports[i]
            futures.add(
                spawn {
                    barrier.wait()
                    for (_ in 0..perThread) {
                        sink.fetchAdd(Int64(transport.send('{}'.unsafeBytes())[0]))
                    }
                })
        }
        jsonrpcBenchSettleGc()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        let start = MonoTime.now()
        barrier.wait()
        for (f in futures) {
            f.get()
        }
        let ns = (MonoTime.now() - start).toNanoseconds()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        for (transport in transports) {
            transport.close()
        }
        server.close()
        println('JSONRPC_READBUF_BENCH case=send_concurrent ops=${ops} threads=${threads} ' +
            'allocTotal=${alloc} allocPerOp=${alloc / ops} wallNs=${ns} nsPerOp=${ns / ops} ' +
            'sink=${sink.load()}')
        @Assert(true, sink.load() >= 0)
    }
}

private func jsonrpcBenchEnabled(): Bool {
    match (getVariable("F_JSONRPC_BENCH")) {
        case Some(v) => v == "1"
        case None => false
    }
}

/** 强制 GC 并等计数稳定：`gc()` 可能异步收尾，紧接着的窗口会把这次 GC 记进去。 */
private func jsonrpcBenchSettleGc(): Unit {
    gc(heavy: true)
    var last = getGCCount()
    var stable = 0
    while (stable < 3) {
        sleep(Duration.millisecond * 5)
        let now = getGCCount()
        if (now == last) {
            stable++
        } else {
            stable = 0
            last = now
        }
    }
}

/**
 * 单次动作的 (堆分配量, 耗时, 有效样本数) 中位数。
 *
 * `getAllocatedHeapSize()` 是「当前存活堆」，只读它会在窗口内发生 GC 时低估分配量，
 * 且大对象分配本身就会诱发 GC（`setGCThreshold` 对大对象无效）。因此按
 * `分配量 = 存活堆增量 + 期间释放量` 计算：进入窗口前先 settle，于是窗口内的释放量
 * 只可能来自本次动作新产生的对象。
 */
private func jsonrpcMeasure(action: () -> Unit): (Int64, Int64, Int64) {
    let allocs = ArrayList<Int64>()
    let times = ArrayList<Int64>()
    var attempts = 0
    while (allocs.size < 5 && attempts < 12) {
        attempts++
        jsonrpcBenchSettleGc()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        let start = MonoTime.now()
        action()
        let ns = (MonoTime.now() - start).toNanoseconds()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        if (alloc >= 0) {
            allocs.add(alloc)
            times.add(ns)
        }
    }
    if (allocs.size == 0) {
        return (-1, 0, 0)
    }
    sort(allocs)
    sort(times)
    (allocs[allocs.size / 2], times[times.size / 2], allocs.size)
}
