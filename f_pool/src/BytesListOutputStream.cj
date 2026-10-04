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

import std.collection.ArrayList
import std.io.OutputStream

public class BytesListOutputStream <: OutputStream & BytesCopyTo & Releasable {
    private var released = false
    BytesListOutputStream(private let list: ArrayList<Array<Byte>>, private let pool: ArrayListPool<Array<Byte>>){}
    public func write(bytes: Array<Byte>): Unit {
        list.add(bytes)
    }
    /**
     * 归还从池中借出的 list。**幂等**：重复调用无副作用。
     * 注意：无论是否写出，都必须调用（或调用 copy），否则池项泄漏。
     */
    /** 待写字节数。 */
    public func byteSize(): ?Int64 {
        var n = 0i64
        for (b in list) {
            n += b.size
        }
        n
    }
    /** 把待写内容拼接成一个数组（不改变/不释放本缓冲）。 */
    public func asBytes(): ?Array<Byte> {
        if (let Some(n) <- byteSize()) {
            let out = Array<Byte>(n, repeat: 0u8)
            var off = 0i64
            for (b in list) {
                for (i in 0..b.size) {
                    out[off + i] = b[i]
                }
                off += b.size
            }
            out
        } else {
            None<Array<Byte>>
        }
    }
    /** 借出后应为空：本缓冲当前是否没有任何待写内容。 */
    public prop isEmpty: Bool {
        get(){
            list.isEmpty()
        }
    }
    /** 复位：丢弃待写内容。仅供池的借用方在检出脏缓冲时兜底使用。 */
    public func reset(): Unit {
        list.clear()
    }
    public func release(): Unit {
        if(released){
            return
        }
        released = true
        pool.giveBack(list)
    }
    public func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit {
        try{
            for(bytes in list){
                to.write(bytes)
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
        clearOnReturning!: Bool = true,
        capacity!: Int64 = 16,
        /** 池耗尽且 `get(timeout: Duration.Max)` 时的等待上限；`Duration.Max` = 真无限等待。 */
        maxWaiting!: Duration = Duration.second * 30
    ): BytesListOutputStreamBuilder {
        BytesListOutputStreamBuilder(initSize, minSize, maxSize, elementLife, checkInterval, clearOnReturning, capacity, maxWaiting)
    }
}
public class BytesListOutputStreamBuilder {
    private let pool: ArrayListPool<Array<Byte>>
    init(
        initSize: Int64, minSize: Int64, maxSize: Int64, elementLife: Duration, checkInterval: Duration, clearOnReturning: Bool, capacity: Int64,
        maxWaiting: Duration
    ){
        pool = ArrayListPool<Array<Byte>>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            elementLife: elementLife,
            checkInterval: checkInterval,
            clearOnReturning: clearOnReturning,
            maxWaiting: maxWaiting)
    }
    public func build(timeout!: Duration = Duration.Max): ?BytesListOutputStream {
        if(let Some(l) <- pool.get(timeout: timeout)){
            BytesListOutputStream(l, pool)
        }else{
            None<BytesListOutputStream>
        }
    }
}