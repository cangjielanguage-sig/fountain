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
package fountain::f_excel

import std.unittest.*
import std.unittest.testmacro.*

/**
 * 共享字符串按已知长度一次分配、直接读入切片：长串跨多次底层读仍完整。
 *
 * 公开 `get()` 会构建并缓存解析表，分配量无法隔离到 `sliceAt`，因此本用例只断言行为。
 */
@Test
public class SharedStringReuse_test {

    @TestCase
    public func longStringSurvivesSlice(): Unit {
        let n: Int64 = 65536
        let long = String(Array<Rune>(n, repeat: r'A'))
        let sst = "<sst><si><t>${long}</t></si></sst>"
        let index = SharedStringIndex.build(sst.toArray())
        try {
            @Expect(index.size(), 1)
            let first = index.get(0)
            @Expect(first.getOrThrow().size, n)
            // 再读一次：路径可能命中缓存，但两次内容都必须完整
            let second = index.get(0)
            @Expect(second.getOrThrow().size, n)
            @Expect(second.getOrThrow() == first.getOrThrow(), true)
        } finally {
            index.close()
        }
    }

}
