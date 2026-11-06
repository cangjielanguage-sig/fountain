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
package fountain::f_protocol.default

import std.collection.ArrayList
import std.env.getVariable
import std.io.{BufferedInputStream, ByteBuffer, OutputStream}
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCTime, setGCThreshold}
import std.time.{DateTime, MonoTime}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.{DataAny, DataString}
import fountain::f_util.crc32

/** 帧头 6B（version + cmd + len）、帧尾 CRC 4B；与 `Message.cj` 的私有常量同口径，测试侧单独声明。 */
private const BENCH_FRAME_HEAD: Int64 = 6
private const BENCH_FRAME_CRC: Int64 = 4
private const BENCH_SMALL_LIMIT: Int64 = 4096

/** 只计数、不落盘的输出端：把编码路径与 socket/磁盘路径隔开。 */
private class CountingNullOutputStream <: OutputStream {
    var total: Int64 = 0
    public func write(buffer: Array<Byte>): Unit {
        total += buffer.size
    }
    public func flush(): Unit {}
}

private func benchEnabled(): Bool {
    match (getVariable("F_PROTOCOL_BENCH")) {
        case Some(v) => v == "1"
        case None => false
    }
}

private func envInt(name: String, defaultValue: Int64): Int64 {
    match (getVariable(name)) {
        case Some(v) => Int64.parse(v)
        case None => defaultValue
    }
}

/** 强制一次 GC 并等 GC 计数稳定：`gc()` 可能异步收尾，紧接着的窗口会把这次 GC 记进去。 */
private func settleGc(): Int64 {
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
    last
}

/** 4KB 级 ASCII 载荷：UTF-8 下每字符 1 字节，避免多字节字符让长度不可预期。 */
private func benchPayload(chars: Int64): String {
    String.fromUtf8(Array<UInt8>(chars, repeat: 97u8))
}

private func benchMessage(chars: Int64): Message {
    // 固定 MessageID（time/pid/tid/hostId）：帧字节跨进程可复现，A/B/C 三阶段才能用 CRC32 直接比对。
    let fixedTime = DateTime.fromUnixTimeStamp(Duration.second * 1_700_000_000)
    let id = MessageID(time: fixedTime, pid: 100, tid: 1, hostId: 7)
    Message(Command.PUBLISH(AT_MOST_ONCE), id, DataString(benchPayload(chars)))
}

/** 取一帧的字节视图（`ByteBuffer.bytes()` 是未读切片，不复制）。 */
private func frameOf(msg: Message): Array<Byte> {
    let buf = ByteBuffer()
    msg.encode().copy(to: buf, closeToOnEnd: false)
    buf.bytes()
}

private func bigEndianInt32(bytes: Array<Byte>, at: Int64): Int64 {
    Int64(bytes[at]) << 24 | Int64(bytes[at + 1]) << 16 | Int64(bytes[at + 2]) << 8 | Int64(bytes[at + 3])
}

/** 分配量（字节/帧）与有效窗口数：窗口内发生 GC 或堆回缩的样本丢弃，取中位数。 */
private func measureAllocPerFrame(msg: Message, sink: OutputStream, allocN: Int64): (Int64, Int64, Int64) {
    let samples = ArrayList<Int64>()
    var attempts = 0
    while (samples.size < 5 && attempts < 12) {
        attempts++
        let allocGcc0 = settleGc()
        let heap0 = getAllocatedHeapSize()
        for (_ in 0..allocN) {
            msg.encode().copy(to: sink, closeToOnEnd: false)
        }
        let heap1 = getAllocatedHeapSize()
        let allocGcc1 = getGCCount()
        if (allocGcc1 == allocGcc0 && heap1 > heap0) {
            samples.add((heap1 - heap0) / allocN)
        }
    }
    if (samples.size == 0) {
        return (-1, 0, attempts)
    }
    samples.sort()
    (samples[samples.size / 2], samples.size, attempts)
}

/**
 * 4KB 帧编码对照基准。
 *
 * 门控：`F_PROTOCOL_BENCH=1` 才执行；否则打印 `SKIP:` 并返回（常规测试不受影响）。
 * 可调：`F_PROTOCOL_BENCH_N`（默认 50000）、`F_PROTOCOL_BENCH_WARMUP`（默认 5000）、
 * `F_PROTOCOL_BENCH_ALLOC_N`（默认 2000）。
 *
 * 输出一行：
 * `BENCH stage=... payloadBytes=... frameBytes=... n=... nsPerFrame=... batchP50=... batchP99=...`
 * `allocBytesPerFrame=... allocLowerBound=... gcPer10k=... gcTimeUs=...`
 */
@Test
public class FrameEncodeBench_test {
    /** 门控默认关闭：未设置环境变量时必须走 SKIP，不拖慢常规测试。 */
    @TestCase
    public func benchGateDefaultsOff(): Unit {
        if (benchEnabled()) {
            println("SKIP: F_PROTOCOL_BENCH=1，门控用例在开启态不做断言")
            return
        }
        @Assert(!benchEnabled())
        println("SKIP: 未设置 F_PROTOCOL_BENCH=1，4KB 帧基准不执行")
    }

    /**
     * C 路径池纪律：连续 2000 帧（超过池预分配 1024）encode→copy 必须不阻塞、字节数正确。
     * 池项泄漏时第 1025 帧起会等待池（默认 5s 超时）并抛错。
     */
    @TestCase
    public func singleBufferPoolReuse2k(): Unit {
        let msg = benchMessage(4000)
        let sink = CountingNullOutputStream()
        let frameBytes = frameOf(msg).size
        let iterations: Int64 = 2_000
        for (_ in 0..iterations) {
            msg.encode().copy(to: sink, closeToOnEnd: false)
        }
        @Assert(sink.total == frameBytes * iterations)
    }

    /** 4KB 载荷编码→解码往返：改造 B/C 的安全网。 */
    @TestCase
    public func encode4kRoundTrip(): Unit {
        let payload = benchPayload(4000)
        let msg = Message(Command.PUBLISH(AT_MOST_ONCE), DataString(payload))
        let frame = frameOf(msg)
        @Assert(frame.size > 4000)
        @Assert(frame.size <= BENCH_SMALL_LIMIT + BENCH_FRAME_HEAD + BENCH_FRAME_CRC)
        let decoded = Message.decode<DataAny>(BufferedInputStream(ByteBuffer(frame)))
        @Assert(decoded.command.value == msg.command.value)
        @Assert(decoded.id == msg.id)
        @Assert(decoded.data.toString() == msg.data.toString())
    }

    /** 帧结构自校验：version / cmd / len / 尾部 CRC 必须与 payload 对得上。 */
    @TestCase
    public func encode4kFrameStructure(): Unit {
        let msg = benchMessage(4000)
        let frame = frameOf(msg)
        @Assert(frame[0] == FRAME_VERSION)
        @Assert(frame[1] == Command.PUBLISH(AT_MOST_ONCE).value)
        let payloadSize = bigEndianInt32(frame, 2)
        @Assert(payloadSize == frame.size - BENCH_FRAME_HEAD - BENCH_FRAME_CRC)
        let expected = crc32(frame[0 .. BENCH_FRAME_HEAD + payloadSize])
        let actual = UInt32(bigEndianInt32(frame, BENCH_FRAME_HEAD + payloadSize))
        @Assert(actual == expected)
    }

    /**
     * 阶段 B 预算：单帧分配不得超过 2.5 × frameBytes。
     * A 基线实测 14044 B/帧（3.49 × 4028），阈值按"实测 × 0.75"取 2.5×。
     * 仅 `F_PROTOCOL_BENCH=1` 时执行，避免拖慢常规回归（也不受 -O0 测试构建影响判定）。
     */
    @TestCase
    public func allocBudgetForCopyTo(): Unit {
        if (!benchEnabled()) {
            println("SKIP: 未设置 F_PROTOCOL_BENCH=1，分配预算用例不执行")
            return
        }
        let msg = benchMessage(4000)
        let sink = CountingNullOutputStream()
        let frameBytes = frameOf(msg).size
        let allocN = envInt("F_PROTOCOL_BENCH_ALLOC_N", 2_000)
        let (perFrame, samples, _) = measureAllocPerFrame(msg, sink, allocN)
        let budget = frameBytes * 5 / 2
        println('BUDGET allocBytesPerFrame=${perFrame} budget=${budget} frameBytes=${frameBytes} samples=${samples}')
        @Assert(samples > 0)
        @Assert(perFrame <= budget)
    }

    /**
     * 阶段 C 预算：单帧分配不得超过 1.5 × frameBytes。
     * B 实测 9591 B/帧（2.38 × 4028），阈值按"实测 × 0.35"的目标取 1.5×；
     * C 的预期是 1 次池化分配（稳态 0 新分配）+ 少量对象。
     */
    @TestCase
    public func allocBudgetForSingleBuffer(): Unit {
        if (!benchEnabled()) {
            println("SKIP: 未设置 F_PROTOCOL_BENCH=1，单缓冲分配预算用例不执行")
            return
        }
        let msg = benchMessage(4000)
        let sink = CountingNullOutputStream()
        let frameBytes = frameOf(msg).size
        let allocN = envInt("F_PROTOCOL_BENCH_ALLOC_N", 2_000)
        let (perFrame, samples, _) = measureAllocPerFrame(msg, sink, allocN)
        let budget = frameBytes * 3 / 2
        println('BUDGET_SINGLE allocBytesPerFrame=${perFrame} budget=${budget} frameBytes=${frameBytes} samples=${samples}')
        @Assert(samples > 0)
        @Assert(perFrame <= budget)
    }

    /**
     * 基准主体。报告数值不做断言（时间断言在 WSL/共享机器上必然抖动）；
     * 采纳与否由 `f_protocol/doc/perf/frame-encode-4k.md` 按 design §7 判定。
     */
    @TestCase
    public func bench4kEncode(): Unit {
        if (!benchEnabled()) {
            println("SKIP: 未设置 F_PROTOCOL_BENCH=1，4KB 帧基准不执行")
            return
        }
        let stage = match (getVariable("F_PROTOCOL_BENCH_STAGE")) {
            case Some(v) => v
            case None => "current"
        }
        let n = envInt("F_PROTOCOL_BENCH_N", 50_000)
        let warmup = envInt("F_PROTOCOL_BENCH_WARMUP", 5_000)
        let allocN = envInt("F_PROTOCOL_BENCH_ALLOC_N", 2_000)
        @Assert(n > 0 && warmup >= 0 && allocN > 0)

        let msg = benchMessage(4000)
        let sink = CountingNullOutputStream()
        let probe = frameOf(msg)
        let frameBytes = probe.size
        let frameCrc = crc32(probe)
        let payloadBytes = bigEndianInt32(probe, 2)

        gc(heavy: true)
        for (_ in 0..warmup) {
            msg.encode().copy(to: sink, closeToOnEnd: false)
        }

        // ① 真实路径：默认 GC 阈值下跑 n 帧，得到含 GC 的 ns/帧与 GC 压力。
        let gcc0 = getGCCount()
        let gct0 = getGCTime()
        let realStart = MonoTime.now()
        for (_ in 0..n) {
            msg.encode().copy(to: sink, closeToOnEnd: false)
        }
        let nsWithGcTotal = (MonoTime.now() - realStart).toNanoseconds()
        let gcTotal = getGCCount() - gcc0
        let gcTimeUs = getGCTime() - gct0
        let gcPer10k = Float64(gcTotal) * 10_000.0 / Float64(n)

        // ② 纯编码：抬高 GC 阈值（1GB，足以覆盖本窗口 ~200MB），排除 GC 干扰后按 10 批采样。
        setGCThreshold(1_000_000)
        gc(heavy: true)
        let batches: Int64 = 10
        let perBatch = n / batches
        @Assert(perBatch > 0)
        let batchNs = ArrayList<Int64>()
        var totalNs: Int64 = 0
        for (_ in 0..batches) {
            let start = MonoTime.now()
            for (_ in 0..perBatch) {
                msg.encode().copy(to: sink, closeToOnEnd: false)
            }
            let elapsed = (MonoTime.now() - start).toNanoseconds()
            batchNs.add(elapsed / perBatch)
            totalNs += elapsed
        }
        batchNs.sort()
        let p50 = batchNs[Int64(batchNs.size / 2)]
        let p99 = batchNs[batchNs.size - 1]

        // ③ 分配：高阈值下多次取窗口，丢弃「窗口内 GC 或堆回缩」的样本，取中位数。
        let (allocPerFrame, allocSamples, allocAttempts) = measureAllocPerFrame(msg, sink, allocN)
        @Assert(allocPerFrame >= 0)
        let allocLowerBound = if (allocSamples < 5) { 1 } else { 0 }

        println(
            'BENCH stage=${stage} payloadBytes=${payloadBytes} frameBytes=${frameBytes} frameCrc32=${frameCrc} ' +
            'n=${n} warmup=${warmup} nsPerFrameWithGc=${nsWithGcTotal / n} nsPerFrame=${totalNs / n} ' +
            'batchP50=${p50} batchP99=${p99} allocBytesPerFrame=${allocPerFrame} allocN=${allocN} ' +
            'allocSamples=${allocSamples} allocAttempts=${allocAttempts} allocLowerBound=${allocLowerBound} ' +
            'gcCount=${gcTotal} gcPer10k=${gcPer10k} gcTimeUs=${gcTimeUs}')
    }
}
