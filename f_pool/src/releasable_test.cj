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

import std.unittest.*
import std.unittest.testmacro.*
import std.io.OutputStream

class ReleasableTestDiscardSink <: OutputStream {
    public func write(bytes: Array<Byte>): Unit {}
    public func flush(): Unit {}
}

class ReleasableTestThrowingSink <: OutputStream {
    public func write(bytes: Array<Byte>): Unit {
        throw Exception('simulated write failure')
    }
    public func flush(): Unit {}
}

// 非阻塞数一遍池中当前可用项（借出后逐个 release 归还）
func releasableTestAvail(b: BytesListOutputStreamBuilder): Int64 {
    let held = ArrayList<BytesListOutputStream>()
    while (let Some(x) <- b.build(timeout: Duration.Zero)) {
        held.add(x)
    }
    let n = held.size
    for (x in held) {
        x.release()
    }
    n
}

@Test
public class ReleasableTest {
    // P0-2 核心：release 归还池项，且必须幂等（重复 release 不得重复归还）
    @TestCase
    public func bytesListReleaseIsIdempotent(): Unit {
        let b = BytesListOutputStream.builder(initSize: 2, minSize: 2, maxSize: 2)
        sleep(Duration.millisecond * 200)
        @Assert(releasableTestAvail(b) == 2)

        let x1 = b.build().getOrThrow()
        let x2 = b.build().getOrThrow()
        @Assert(releasableTestAvail(b) == 0)   // 全借出，池空

        x1.release()
        @Assert(releasableTestAvail(b) == 1)
        x1.release()                            // 幂等：不得变成 2
        @Assert(releasableTestAvail(b) == 1)

        x2.release()
        @Assert(releasableTestAvail(b) == 2)
    }

    // P0-2：ChainedBytesCopyTo.release 必须释放全部子项
    @TestCase
    public func chainedReleaseReleasesChildren(): Unit {
        let b = BytesListOutputStream.builder(initSize: 2, minSize: 2, maxSize: 2)
        sleep(Duration.millisecond * 200)
        let x1 = b.build().getOrThrow()
        let x2 = b.build().getOrThrow()
        @Assert(releasableTestAvail(b) == 0)

        let arr: Array<BytesCopyTo> = [x1, x2]
        let chain = ChainedBytesCopyTo(arr)
        chain.release()
        @Assert(releasableTestAvail(b) == 2)
    }

    // P0-1 底层保证：copy 过程中目标 write 抛异常，子项仍须在 finally 里归还
    @TestCase
    public func chainedCopyFailureStillReleases(): Unit {
        let b = BytesListOutputStream.builder(initSize: 1, minSize: 1, maxSize: 1)
        sleep(Duration.millisecond * 200)
        let x1 = b.build().getOrThrow()
        x1.write([1u8])

        let arr: Array<BytesCopyTo> = [x1]
        let chain = ChainedBytesCopyTo(arr)
        var threw = false
        try {
            chain.copy(to: ReleasableTestThrowingSink(), closeFromOnEnd: false, closeToOnEnd: false)
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw)
        @Assert(releasableTestAvail(b) == 1)     // 已归还
        @Assert(releasableTestAvail(b) == 1)     // 再数一次仍为 1（没有重复归还）
    }

    // POOL-9（bug-pool.md §2.4）：release() 之后不得再写 —— 否则内容落进池项，被下一个借用者读到
    @TestCase
    public func writeAfterReleaseMustThrow(): Unit {
        let b = BytesListOutputStream.builder(initSize: 1, minSize: 1, maxSize: 1, clearOnReturning: false)
        sleep(Duration.millisecond * 200)
        let first = b.build().getOrThrow()
        first.write([1u8, 2u8, 3u8])
        first.release()
        var threw = false
        try {
            first.write([9u8, 9u8])
        } catch (_: IllegalStateException) {
            threw = true
        }
        @Assert(threw)                           // 修前：不抛，释放后的 2 字节落进池项
        let second = b.build().getOrThrow()
        // 池项里只应剩下 release **之前**写的 3 字节（`clearOnReturning: false` 时不代清理是池的口径）；
        // 修前这里是 5 字节 —— 多出来的 2 字节正是「释放后仍可写」漏进池项的脏数据（探针 useafterrelease 实测 5）。
        @Assert(second.byteSize() == Some(3))
        second.release()
    }

    // POOL-9（§2.4）：release() 之后不得再读/复位/写出去
    @TestCase
    public func readOrCopyAfterReleaseMustThrow(): Unit {
        let b = BytesListOutputStream.builder(initSize: 1, minSize: 1, maxSize: 1, clearOnReturning: false)
        sleep(Duration.millisecond * 200)
        let x = b.build().getOrThrow()
        x.write([7u8])
        x.release()
        var asBytesThrew = false
        try {
            x.asBytes()
        } catch (_: IllegalStateException) {
            asBytesThrew = true
        }
        var resetThrew = false
        try {
            x.reset()
        } catch (_: IllegalStateException) {
            resetThrew = true
        }
        var copyThrew = false
        try {
            x.copy(to: ReleasableTestDiscardSink(), closeFromOnEnd: false, closeToOnEnd: false)
        } catch (_: IllegalStateException) {
            copyThrew = true
        }
        @Assert(asBytesThrew)
        @Assert(resetThrew)
        @Assert(copyThrew)
        x.release()                              // 幂等：仍然不抛
        @Assert(releasableTestAvail(b) == 1)
    }
}
