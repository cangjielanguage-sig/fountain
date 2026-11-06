/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_pool

import std.io.OutputStream

/**
 * 单缓冲编码输出：内部是一段可增长 `Array<Byte>`，不再维护「数组列表」。
 *
 * - `write` 直接 `copyTo` 进缓冲区（一次 memcpy），`asBytes()` 返回 `[start, start+len)` 的**视图**（零拷贝）；
 * - `start` 是帧头预留量（headroom）：上层可让编码从 `start` 处开始，之后整帧视图向前包含 headroom、
 *   向后包含 tail（如 CRC），从而把「载荷 → 帧」的整段组装拷贝省掉；
 * - 池项尺寸固定（`arraySize`），扩容后的缓冲不再归还池（原池项在扩容时已归还），避免尺寸不符。
 */
public class BytesListOutputStream <: OutputStream & BytesCopyTo & Releasable {
    private var released = false
    private var buf: Array<Byte>
    private let pooledSize: Int64
    private let pool: ArrayPool<Byte>
    private let start: Int64
    private var len = 0i64

    BytesListOutputStream(buf: Array<Byte>, pool: ArrayPool<Byte>, headroom: Int64) {
        this.buf = buf
        this.pooledSize = buf.size
        this.pool = pool
        this.start = headroom
    }
    /**
     * 归还之后的缓冲**不得再用**：`release()` 已经把底层 buff 还进池里，再写就会把内容留在池项上，
     * 被下一个借用者当成自己的字节（见 .autocode/bugs/bug-pool.md §2.4 `POOL-9`）。
     */
    private func checkNotReleased(): Unit {
        if (released) {
            throw IllegalStateException('bytes output stream is released')
        }
    }
    private func ensureCapacity(extra: Int64): Unit {
        let need = start + len + extra
        if (need <= buf.size) {
            return
        }
        var newSize = if (buf.size > 0) {
            buf.size
        } else {
            256
        }
        while (newSize < need) {
            newSize = newSize * 2
        }
        let grown = Array<Byte>(newSize, repeat: 0u8)
        buf.copyTo(grown, start, start, len)
        if (buf.size == pooledSize) {
            pool.giveBack(buf)
        }
        buf = grown
    }
    public func write(bytes: Array<Byte>): Unit {
        checkNotReleased()
        if (bytes.size == 0) {
            return
        }
        ensureCapacity(bytes.size)
        bytes.copyTo(buf, 0, start + len, bytes.size)
        len += bytes.size
    }
    /** 待写字节数。 */
    public func byteSize(): ?Int64 {
        Some(len)
    }
    /** 待写内容视图（`[start, start+len)`，零拷贝；修改会影响缓冲本身）。 */
    public func asBytes(): ?Array<Byte> {
        checkNotReleased()
        Some(buf[start .. start + len])
    }
    /**
     * 整帧视图：`[start-headroom, start+len+tail)`。
     *
     * 供帧装配使用：调用方在 `[0, headroom)` 写帧头、在 `[headroom+len, headroom+len+tail)` 写帧尾，
     * 载荷本身留在原位，不再整段拷贝。容量不足或预留量不匹配时返回 `None`，调用方回退普通组装。
     */
    public func frameBytes(headroom: Int64, tail: Int64): ?Array<Byte> {
        checkNotReleased()
        if (start < headroom) {
            return None
        }
        let end = start + len + tail
        if (end > buf.size) {
            return None
        }
        Some(buf[start - headroom .. end])
    }
    /** 借出后应为空：本缓冲当前是否没有任何待写内容。 */
    public prop isEmpty: Bool {
        get(){
            len == 0
        }
    }
    /** 复位：丢弃待写内容。仅供池的借用方在检出脏缓冲时兜底使用。 */
    public func reset(): Unit {
        checkNotReleased()
        len = 0
    }
    /**
     * 归还从池中借出的缓冲。**幂等**：重复调用无副作用（`copy` 的 `finally` 也靠它兜底），
     * 所以它自己**不**受 `checkNotReleased` 约束。
     * 注意：无论是否写出，都必须调用（或调用 copy），否则池项泄漏。
     */
    public func release(): Unit {
        if (released) {
            return
        }
        released = true
        if (buf.size == pooledSize) {
            pool.giveBack(buf)
        }
    }
    public func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit {
        checkNotReleased()
        try{
            if (len > 0) {
                to.write(asBytes().getOrThrow())
            }
        }finally{
            release()
            if(closeToOnEnd && let r: Resource <- to && !r.isClosed()){
                r.close()
            }
        }
    }
    public static func builder(
        initSize!: Int64 = 1024,
        minSize!: Int64 = 1024,
        maxSize!: Int64 = 1024,
        elementLife!: Duration = Duration.Max,
        checkInterval!: Duration = Duration.Max,
        clearOnReturning!: Bool = false,
        capacity!: Int64 = 8192,
        /** 池耗尽且 `get(timeout: Duration.Max)` 时的等待上限；`Duration.Max` = 真无限等待。 */
        maxWaiting!: Duration = Duration.second * 30
    ): BytesListOutputStreamBuilder {
        BytesListOutputStreamBuilder(initSize, minSize, maxSize, elementLife, checkInterval, clearOnReturning, capacity, maxWaiting)
    }
}
public class BytesListOutputStreamBuilder {
    private let pool: ArrayPool<Byte>
    private let bufferSize: Int64
    init(
        initSize: Int64, minSize: Int64, maxSize: Int64, elementLife: Duration, checkInterval: Duration,
        clearOnReturning: Bool, capacity: Int64, maxWaiting: Duration
    ){
        this.bufferSize = capacity
        pool = ArrayPool<Byte>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            elementLife: elementLife,
            checkInterval: checkInterval,
            clearOnReturning: clearOnReturning,
            maxWaiting: maxWaiting,
            arraySize: capacity)
    }
    public func build(timeout!: Duration = Duration.Max, headroom!: Int64 = 0): ?BytesListOutputStream {
        if(let Some(buf) <- pool.get(timeout: timeout)){
            BytesListOutputStream(buf, pool, headroom)
        }else{
            None<BytesListOutputStream>
        }
    }
}
