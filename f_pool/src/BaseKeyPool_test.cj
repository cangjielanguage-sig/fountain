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
package fountain::f_pool

import std.unittest.*
import std.unittest.testmacro.*
import std.sync.AtomicInt64

/** `BaseKeyPool` 的记账一致性（见 .autocode/bugs/bug-archived-on-20261004.md 7.2：size 与实际可借数不能脱钩）。 */
@Test
public class BaseKeyPoolTest {
    @TestCase
    public func destroyMustSyncSize(){
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10)
        pool.add('k', Object())
        pool.add('k', Object())
        pool.add('other', Object())
        @Assert(pool.size, 3)
        @Assert(pool.keyedSize('k'), 2)
        // 注意：捕获可变局部变量的 lambda 只能直接调用（仓颉限制）⇒ 用 AtomicInt64 记数
        let destroyed = AtomicInt64(0)
        pool.destroy{_, _ => destroyed.fetchAdd(1)}
        @Assert(destroyed.load(), 3)
        // destroy 之后 size 必须归零：否则调用方会以为池已满，再也不新建池项，get 永久取不到东西
        @Assert(pool.size, 0)
        @Assert(pool.keyedSize('k'), 0)
    }
}
