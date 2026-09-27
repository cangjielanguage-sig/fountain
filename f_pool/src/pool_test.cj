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

public class Test {
    var valid = true
    func destroy(): Unit {
        println('destroy ${valid}')
    }
}

@Test
public class PoolTest {
    @TestCase
    public func test0(): Unit {
        // 1) 非阻塞 get：池中没有空闲项时返回 None（initSize=0，不存在预创建项）
        let empty = Pool<Test>(initSize: 0, minSize: 0, maxSize: 2, idleTimeout: Duration.second * 10,
            checkInterval: Duration.second, creator: {=> Test()}, checker: {x: Test => x.valid},
            destroier: {x => x.destroy()})
        sleep(Duration.millisecond * 50)
        @Assert(empty.get(timeout: Duration.Zero).isNone())

        // 2) 容量 maxSize=2：可取满 2 个；第 3 个（有限超时）取不到；归还后可再取
        let pool = Pool<Test>(initSize: 2, minSize: 0, maxSize: 2, idleTimeout: Duration.second * 10,
            checkInterval: Duration.second, creator: {=> Test()}, checker: {x: Test => x.valid},
            destroier: {x => x.destroy()})
        sleep(Duration.millisecond * 200)
        let o1 = pool.get(timeout: Duration.second)
        let o2 = pool.get(timeout: Duration.second)
        @Assert(o1.isSome())
        @Assert(o2.isSome())
        @Assert(pool.get(timeout: Duration.millisecond * 50).isNone())

        pool.giveBack(o1.getOrThrow())
        let o3 = pool.get(timeout: Duration.second)
        @Assert(o3.isSome())
        pool.giveBack(o2.getOrThrow())
        pool.giveBack(o3.getOrThrow())

        // 3) 长时间空闲后仍可服务（minSize=0 允许被回收后按需重建）
        sleep(Duration.second * 3)
        let o4 = pool.get(timeout: Duration.second)
        @Assert(o4.isSome())
        pool.giveBack(o4.getOrThrow())
    }
}
