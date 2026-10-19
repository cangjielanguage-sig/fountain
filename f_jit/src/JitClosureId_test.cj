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
package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.test.TCase

/** Q5.5：`JitClosureId` 值类型（m2 §14.3、design-m2 §6.1.3）。 */
@Test
public class JitClosureId_test {
    /** 构造保真 + `INVALID = 0`。 */
    @TestCase
    public func carriesIdAndInvalidZero(): Unit {
        let id = JitClosureId(42)
        @Assert(id.id, 42)
        @Assert(JitClosureId.INVALID, 0)
        @Assert(JitClosureId(JitClosureId.INVALID).id, 0)
        @Assert(TCase.hit('T49/jit-closure-id', id.id == 42), true)
    }

    /** 值语义：拷贝后 ID 相同，且逐位相等。 */
    @TestCase
    public func copyKeepsValue(): Unit {
        let a = JitClosureId(7)
        let b = a
        @Assert(b.id, a.id)
        @Assert(b == a, true)
        @Assert(a == JitClosureId(7), true)
        @Assert(a == JitClosureId(8), false)
        @Assert(TCase.hit('T49/jit-closure-id-copy', b.id == 7), true)
    }
}
