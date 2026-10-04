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
package fountain::f_cache

import std.unittest.*
import std.unittest.testmacro.*
import std.time.DateTime

@Test
public class HeapCache_test {
    @TestCase
    public func test(): Unit {
        let cache = HeapCache<Test>(maxSize: 2)
        cache.set("test1", Test())
        @Assert(cache.get("test1").isSome())
        sleep(Duration.second)
        cache.set("test2", Test())
        let test1 = cache.get('test1').isSome()
        @Assert(test1)
        @Assert(cache.get('test1')?.value, cache.get('test1')?.value)
        @Assert(cache.getOrDefault("test99999999", Test(8888888)).value, 8888888)
        cache.set("test3", Test())
        sleep(2 * Duration.second)
        @Assert(cache.contains("test2"))
        @Assert(cache.contains("test1"))
        @Assert(!cache.contains("test3"))
        sleep(5 * Duration.second)
        @Assert(!cache.contains("test1"))
        @Assert(!cache.contains("test3"))
    }

    @TestCase
    public func testSetLifeOnNewKey(): Unit {
        //checkDuration 放大到 30s：本用例只考察「寿命判定」，不让定时清扫介入
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, maxSize: 100,
            checkDuration: Duration.second * 30)
        //新建键：life 必须生效
        cache.set('newLife', Test(1), life: Duration.millisecond * 100)
        //已存在键：life 生效（修复前就正确，作为对照）
        cache.set('updLife', Test(2))
        cache.set('updLife', Test(3), life: Duration.millisecond * 100)
        //新建键 + dieAt：等价于「一次性 + 指定死亡时间」，必须生效
        cache.set('newDieAt', Test(4), DateTime.now() + Duration.millisecond * 100)
        sleep(Duration.millisecond * 300)
        @Assert(false, cache.contains('newLife'))
        @Assert(false, cache.contains('updLife'))
        @Assert(false, cache.contains('newDieAt'))
    }
}

public class Test <: ToString {
    private static var serial = 0
    public let value: Int64
    public init() {
        serial++
        value = serial
    }
    public init(val: Int64) {
        this.value = val
    }
    public func toString(): String {
        "Test(${value})"
    }
}
