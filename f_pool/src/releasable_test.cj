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
}
