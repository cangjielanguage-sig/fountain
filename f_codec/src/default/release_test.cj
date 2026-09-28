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
package fountain::f_codec.default

import std.unittest.*
import std.unittest.testmacro.*

func codecReleaseTestAvail(b: BytesListOutputStreamBuilder): Int64 {
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
public class DefaultCodecReleaseTest {
    // P0-2：DefaultCodec.release 必须归还 encode 期间借出的全部池项，且幂等
    @TestCase
    public func releaseReturnsInputsAndIsIdempotent(): Unit {
        let b = BytesListOutputStream.builder(initSize: 4, minSize: 4, maxSize: 4)
        DefaultCodec.setBytesPool(b)
        sleep(Duration.millisecond * 200)
        @Assert(codecReleaseTestAvail(b) == 4)

        let codec = DefaultCodec()
        let _ = codec.encode(Int64(42))          // 触发 lastBuffer() 借一个缓冲
        @Assert(codecReleaseTestAvail(b) == 3)

        codec.release()
        @Assert(codecReleaseTestAvail(b) == 4)   // 已归还
        codec.release()                           // 幂等
        @Assert(codecReleaseTestAvail(b) == 4)

        // 恢复默认 builder，避免影响同进程其它用例
        DefaultCodec.setBytesPool(BytesListOutputStream.builder(initSize: 1024, minSize: 1024, maxSize: 1024))
    }
}
