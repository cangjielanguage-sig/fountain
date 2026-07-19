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
        let pool = Pool<Test>(initSize: 1, minSize: 1, maxSize: 2, idleTimeout: Duration.second * 10,
            checkInterval: Duration.second, creator: {=> Test()}, checker: {x: Test => x.valid},
            destroier: {x => x.destroy()})
        sleep(Duration.millisecond)
        let o1 = pool.get(timeout: Duration.Zero)
        let o2 = pool.get(timeout: Duration.second)
        let o3 = pool.get(timeout: Duration.second)
        @Assert(o1.isSome(),false)
        @Assert(o2.isSome(),true)
        @Assert(o3.isSome(),true)
        let o4 = pool.get(timeout: Duration.millisecond)
        @Assert(o4.isNone(),true)
        pool.giveBack(o2.getOrThrow())
        let o5 = pool.get(timeout: Duration.second)
        @Assert(o5.isSome(),true)
        pool.giveBack(o3.getOrThrow())
        sleep(Duration.second * 10)
        let o6 = pool.get(timeout: Duration.second)
        @Assert(o6.isSome(),true)
        pool.giveBack(o6.getOrThrow())
    }
}
