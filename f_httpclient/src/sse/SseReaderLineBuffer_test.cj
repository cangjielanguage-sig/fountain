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
package fountain::f_httpclient.sse

import std.collection.ArrayList
import std.env.getVariable
import std.io.InputStream
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.sort.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

/** 每次 `read` 最多返回 `maxChunk` 字节，用于强制把一行拆到多块。 */
class ThrottledStream <: InputStream {
    private let bytes: Array<Byte>
    private let maxChunk: Int64
    private var offset: Int64 = 0

    init(text: String, maxChunk: Int64) {
        this.bytes = text.toArray()
        this.maxChunk = maxChunk
    }

    public func read(buffer: Array<Byte>): Int64 {
        if(offset >= bytes.size){
            return 0
        }
        var n = bytes.size - offset
        if(n > maxChunk){
            n = maxChunk
        }
        if(n > buffer.size){
            n = buffer.size
        }
        for(i in 0 .. n){
            buffer[i] = bytes[offset + i]
        }
        offset += n
        n
    }
}

/** 可复位的字节流：基准里同一个字节数组要跑多次样本，避免把 `toArray()` 拷贝算进窗口。 */
class BenchStream <: InputStream {
    private let bytes: Array<Byte>
    private var offset: Int64 = 0

    init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func read(buffer: Array<Byte>): Int64 {
        if(offset >= bytes.size){
            return 0
        }
        var n = bytes.size - offset
        if(n > buffer.size){
            n = buffer.size
        }
        for(i in 0 .. n){
            buffer[i] = bytes[offset + i]
        }
        offset += n
        n
    }

    func reset(): Unit {
        offset = 0
    }
}

private func repeatLines(line: String, times: Int64): String {
    let builder = StringBuilder()
    for(_ in 0 .. times){
        builder.append(line)
    }
    builder.toString()
}

private func repeatByte(c: UInt8, n: Int64): String {
    String.fromUtf8(Array<Byte>(n, repeat: c))
}

/** 在测试内重现旧算法：每行 `ArrayList<Byte>` + 切片 + `toArray()` + `fromUtf8`。 */
private func freshReadCommentLines(bytes: Array<Byte>): Int64 {
    var i: Int64 = 0
    var sink: Int64 = 0
    while(i < bytes.size){
        let buf = ArrayList<Byte>()
        while(true){
            let b = bytes[i]
            i++
            if(b == 0x0A){
                break
            }
            buf.add(b)
        }
        var end = buf.size
        if(end > 0 && buf[end - 1] == 0x0D){
            end--
        }
        let text = String.fromUtf8(buf[0 .. end].toArray())
        sink += text.size
    }
    sink
}

private func sseBenchEnabled(): Bool {
    match(getVariable("F_HTTPCLIENT_SSE_BENCH")){
        case Some(v) => v == "1"
        case None => false
    }
}

/** 是否在基准中做分配断言；只有在 `-O2` 参考构建下才应开启。 */
private func sseBenchStrict(): Bool {
    match(getVariable("F_HTTPCLIENT_SSE_BENCH_STRICT")){
        case Some(v) => v == "1"
        case None => false
    }
}

/** 强制 GC 并等计数稳定：`gc()` 可能异步收尾，紧接着的窗口会把这次 GC 记进去。 */
private func sseBenchSettleGc(): Unit {
    gc(heavy: true)
    var last = getGCCount()
    var stable = 0
    while(stable < 3){
        sleep(Duration.millisecond * 5)
        let now = getGCCount()
        if(now == last){
            stable++
        }else{
            stable = 0
            last = now
        }
    }
}

/**
 * 单次动作的 (堆分配量, 耗时, 有效样本数) 中位数。
 *
 * `getAllocatedHeapSize()` 是「当前存活堆」，只读它会在窗口内发生 GC 时低估分配量。
 * 因此按 `分配量 = 存活堆增量 + 期间释放量` 计量：进入窗口前先 settle，
 * 窗口内的释放量只可能来自本次动作新产生的对象。
 */
private func sseMeasure(action: () -> Int64): (Int64, Int64, Int64) {
    let allocs = ArrayList<Int64>()
    let times = ArrayList<Int64>()
    var attempts = 0
    var sink: Int64 = 0
    while(allocs.size < 5 && attempts < 12){
        attempts++
        sseBenchSettleGc()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        let start = MonoTime.now()
        sink += action()
        let ns = (MonoTime.now() - start).toNanoseconds()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        if(alloc >= 0){
            allocs.add(alloc)
            times.add(ns)
        }
    }
    if(sink < 0){
        return (-2, 0, allocs.size)
    }
    if(allocs.size == 0){
        return (-1, 0, 0)
    }
    sort(allocs)
    sort(times)
    (allocs[allocs.size / 2], times[times.size / 2], allocs.size)
}

/** 行缓冲复用的等价性与分配基准。 */
@Test
public class SseReaderLineBufferTest {

    /** 1000 条短事件连续读取：内容正确，行缓冲被重复使用。 */
    @TestCase
    func testShortLinesReuse(): Unit {
        let lines: Int64 = 1000
        let builder = StringBuilder()
        for(i in 0 .. lines){
            builder.append('data: v${i}\n\n')
        }
        // 总量超过 8 KiB，`streamOf` 的单块假流会截断，这里按 4 KiB 分块喂入
        let reader = SseReader(ThrottledStream(builder.toString(), 4096))
        var seq: Int64 = 0
        while(let Some(event) <- reader.next()){
            @Expect(event.data, 'v${seq}')
            seq++
        }
        @Expect(seq, lines)
    }

    /** 单行 1000 B（超过初始 256 B）：内容与长度精确。 */
    @TestCase
    func testLongLineGrowsBuffer(): Unit {
        let long = repeatByte(0x78, 1000)
        let reader = SseReader(streamOf('data: ${long}\n\n'))
        let event = reader.next().getOrThrow()
        @Expect(event.data.size, 1000)
        @Expect(event.data, long)
    }

    /** 9000 B 的行被 7 字节一块喂入：跨块补齐后逐字节一致。 */
    @TestCase
    func testLineAcrossManyChunks(): Unit {
        let long = repeatByte(0x78, 9000)
        let reader = SseReader(ThrottledStream('data: ${long}\n\n', 7))
        let event = reader.next().getOrThrow()
        @Expect(event.data.size, 9000)
        @Expect(event.data, long)
    }

    /** `\r` 与 `\n` 分属不同块：仍按 CRLF 处理。 */
    @TestCase
    func testCrlfSplitAcrossChunks(): Unit {
        let reader = SseReader(ChunkStream(ArrayList<(Duration, String)>([
            (Duration.Zero, 'data: a\r'),
            (Duration.Zero, '\ndata: b\r'),
            (Duration.Zero, '\n\r\n')
        ])))
        @Expect(reader.next()?.data ?? '', 'a\nb')
    }

    /** EOF 半行保留末尾 `\r`（与改造前一致）。 */
    @TestCase
    func testCrAtEofIsPreserved(): Unit {
        let reader = SseReader(streamOf('data: a\r'))
        @Expect(reader.next()?.data ?? '', 'a\r')
    }

    /** 长行之后再读短行：上一条长行的尾部不得泄漏。 */
    @TestCase
    func testStaleTailDoesNotLeak(): Unit {
        let long = repeatByte(0x78, 1000)
        let reader = SseReader(streamOf('data: ${long}\n\ndata: b\n\n'))
        @Expect(reader.next()?.data ?? '', long)
        @Expect(reader.next()?.data ?? '', 'b')
    }

    /** 行长度恰好等于 `maxLineBytes`（`:` + 15 B = 16 B）：读取成功。 */
    @TestCase
    func testMaxLineBytesExactlyAtLimit(): Unit {
        let reader = SseReader(streamOf(':' + repeatByte(0x30, 15) + '\n\n'), maxLineBytes: 16)
        @Expect(reader.next().isNone(), true)
    }

    /** 行长 `maxLineBytes + 1`（`:` + 16 B = 17 B）：抛 `SseLineTooLongException`。 */
    @TestCase
    func testMaxLineBytesOverLimit(): Unit {
        let reader = SseReader(streamOf(':' + repeatByte(0x30, 16) + '\n'), maxLineBytes: 16)
        var thrown = false
        try{
            reader.next()
        }catch(e: SseLineTooLongException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    /** 没有 `\n` 的半行：按残留内容返回。 */
    @TestCase
    func testHalfLineAtEof(): Unit {
        let reader = SseReader(streamOf('data: abc'))
        @Expect(reader.next()?.data ?? '', 'abc')
    }

    /** 保留多个已返回事件后再比对：行缓冲复用不得污染先前构造的 String。 */
    @TestCase
    func testRetainedEventsAreIndependent(): Unit {
        let reader = SseReader(streamOf('data: first\n\ndata: second\n\ndata: third\n\n'))
        let first = reader.next()?.data ?? ''
        let second = reader.next()?.data ?? ''
        let third = reader.next()?.data ?? ''
        @Expect(reader.next().isNone(), true)
        @Expect(first, 'first')
        @Expect(second, 'second')
        @Expect(third, 'third')
    }

    /** 门控默认关闭：未设置环境变量时必须走 SKIP，不拖慢常规测试。 */
    @TestCase
    func testBenchGateDefaultsOff(): Unit {
        if(sseBenchEnabled()){
            println("SKIP: F_HTTPCLIENT_SSE_BENCH=1，门控用例在开启态不做断言")
            return
        }
        println("SKIP: 未设置 F_HTTPCLIENT_SSE_BENCH=1，SSE 行缓冲基准不执行")
    }

    /**
     * `F_HTTPCLIENT_SSE_BENCH=1` 门控的分配基准。
     *
     * 断言只用确定性指标：`line_reuse` 摊销 `<= 96 B/行`，且不到 `line_fresh`（重现旧算法）的一半；
     * 耗时只打印（`-O0` 测试构建，不代表生产数值）。
     *
     * 注意：`-O0` 下每次 `Array<Byte>` 下标读写会记 16 B 堆分配，每行仅流缓冲读取就超过 96 B；
     * 门控须按 `design.md` §10 的 `-O2` 口径执行（临时给 `f_httpclient/cjpm.toml` 追加 `-O2`，测完回退）。
     */
    @TestCase
    func testBenchLineAllocation(): Unit {
        if(!sseBenchEnabled()){
            println("SKIP: 未设置 F_HTTPCLIENT_SSE_BENCH=1，SSE 行缓冲基准不执行")
            return
        }
        // case=line_reuse：20000 条注释行，一次 next() 读完
        let shortOps: Int64 = 20000
        let shortBytes = repeatLines(': aaaa\n', shortOps).toArray()
        let shortStream = BenchStream(shortBytes)
        let (reuseAlloc, reuseNs, reuseSamples) = sseMeasure({ =>
            shortStream.reset()
            let reader = SseReader(shortStream)
            let result = reader.next()
            if(result.isNone()){
                1
            }else{
                2
            }
        })
        // case=line_fresh：同窗口内重现旧算法的每行分配
        let (freshAlloc, freshNs, freshSamples) = sseMeasure({ =>
            freshReadCommentLines(shortBytes)
        })
        @Assert(reuseSamples > 0 && freshSamples > 0)
        let reusePerLine = reuseAlloc / shortOps
        let freshPerLine = freshAlloc / shortOps
        println('SSE_LINEBUF_BENCH case=line_reuse ops=${shortOps} allocTotal=${reuseAlloc} ' +
            'allocPerLine=${reusePerLine} nsPerLine=${reuseNs / shortOps} samples=${reuseSamples}')
        println('SSE_LINEBUF_BENCH case=line_fresh ops=${shortOps} allocTotal=${freshAlloc} ' +
            'allocPerLine=${freshPerLine} nsPerLine=${freshNs / shortOps} samples=${freshSamples}')
        if(sseBenchStrict()){
            @Assert(reusePerLine <= 96)
            @Assert(reuseAlloc * 2 < freshAlloc)
        }else{
            println('RECORD ONLY: -O0 下数组下标读写会额外计入分配；断言需 -O2 + F_HTTPCLIENT_SSE_BENCH_STRICT=1')
        }

        // case=line_long：8192 B 行 × 200，扩容只发生在第一次（耗时只打印）
        let longOps: Int64 = 200
        let longLine = ': ' + repeatByte(0x78, 8189) + '\n'
        let longBytes = repeatLines(longLine, longOps).toArray()
        let longStream = BenchStream(longBytes)
        let (longAlloc, longNs, longSamples) = sseMeasure({ =>
            longStream.reset()
            let reader = SseReader(longStream)
            let result = reader.next()
            if(result.isNone()){
                1
            }else{
                2
            }
        })
        @Assert(longSamples > 0)
        println('SSE_LINEBUF_BENCH case=line_long ops=${longOps} allocTotal=${longAlloc} ' +
            'allocPerLine=${longAlloc / longOps} nsPerLine=${longNs / longOps} samples=${longSamples}')

        // case=event_small：5000 条 data: x 事件端到端 next()
        let eventOps: Int64 = 5000
        let eventBytes = repeatLines('data: x\n\n', eventOps).toArray()
        let eventStream = BenchStream(eventBytes)
        let (eventAlloc, eventNs, eventSamples) = sseMeasure({ =>
            eventStream.reset()
            let reader = SseReader(eventStream)
            var sink: Int64 = 0
            while(let Some(event) <- reader.next()){
                sink += event.data.size
            }
            sink
        })
        @Assert(eventSamples > 0)
        println('SSE_LINEBUF_BENCH case=event_small ops=${eventOps} allocTotal=${eventAlloc} ' +
            'allocPerEvent=${eventAlloc / eventOps} nsPerEvent=${eventNs / eventOps} samples=${eventSamples}')
    }
}
