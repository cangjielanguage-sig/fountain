/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_cache

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class HeapCache_test {
    @TestCase
    public func test(): Unit {
        let cache = HeapCache<Test>(maxSize: 2)
        cache.set("test1", Test())
        sleep(Duration.second)
        cache.set("test2", Test())
        @Assert(cache.get("test1").isSome())
        @Assert(cache.get("test1").isSome())
        @Assert(cache.get('test1')?.value, cache.get('test1')?.value)
        @Assert(cache.getOrDefault("test99999999", Test(8888888)).value, 8888888)
        cache.set("test3", Test())
        sleep(2 * Duration.second)
        @Assert(!cache.contains("test2"))
        @Assert(cache.contains("test1"))
        @Assert(cache.contains("test3"))
        sleep(5 * Duration.second)
        @Assert(!cache.contains("test1"))
        @Assert(!cache.contains("test3"))
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
