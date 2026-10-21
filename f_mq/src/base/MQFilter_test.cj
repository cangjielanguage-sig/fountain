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
package fountain::f_mq.base

import std.collection.{HashMap, TreeSet}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*

@DataAssist[props fields]
public class TestFilterBody {
    private var enabled: Bool = false
    private var age: Int64 = 0
    private var count: Int64 = 0
    private var level: Int64 = 0

    public init() {}

    public init(enabled: Bool, age: Int64, count: Int64, level: Int64) {
        this.enabled = enabled
        this.age = age
        this.count = count
        this.level = level
    }
}

@Test
class MQFilterTest {
    @TestCase
    public func emptyFilterAlwaysMatches(): Unit {
        let filter = MQFilter.compile("")
        @Assert(filter.path.isEmpty())
        @Assert(filter.matches(DataNone.INSTANCE))
        @Assert(filter.matches(3i64.toData()))
        @Assert(filter.matches(TestFilterBody(true, 40, 3, 3).toData()))
    }

    @TestCase
    public func booleanPath(): Unit {
        let filter = MQFilter.compile("$.enabled")
        @Assert(filter.matches(TestFilterBody(true, 40, 3, 3).toData()))
        @Assert(!filter.matches(TestFilterBody(false, 40, 3, 3).toData()))
        // 缺失路径 → 无元素 → 假
        @Assert(!MQFilter.compile("$.missing").matches(TestFilterBody(true, 1, 2, 3).toData()))
    }

    @TestCase
    public func predicateExpression(): Unit {
        let filter = MQFilter.compile("$[?(@.age > 30)]")
        // `$[?...]` 是对集合的谓词：BODY 为集合时按 f_data.path 语义求值
        let olders: Array<TestFilterBody> = [TestFilterBody(true, 40, 1, 1)]
        let youngers: Array<TestFilterBody> = [TestFilterBody(true, 20, 1, 1)]
        @Assert(filter.matches(olders.toData()))
        @Assert(!filter.matches(youngers.toData()))
    }

    @TestCase
    public func existsMeansTrueButNoneMeansFalse(): Unit {
        // 非布尔值：存在即真
        @Assert(MQFilter.compile("$.count").matches(TestFilterBody(true, 1, 3, 1).toData()))
        // 缺失 → 假
        @Assert(!MQFilter.compile("$.count").matches(DataNone.INSTANCE))
        // 选中 null → 假
        let body = TestFilterBody(true, 1, 3, 1)
        @Assert(!MQFilter.compile("$.nothing").matches(body.toData()))
    }

    @TestCase
    public func containerBodiesSupportPathEvaluation(): Unit {
        // HashMap：按字段取值
        let map = HashMap<String, Int64>()
        map.add("age", 40)
        @Assert(MQFilter.compile("$.age").matches(map.toData()))
        @Assert(!MQFilter.compile("$.missing").matches(map.toData()))

        // Array：按下标取值
        let array: Array<Int64> = [10, 20, 30]
        @Assert(MQFilter.compile("$[0]").matches(array.toData()))
        // 越界 → 无元素 → 假
        @Assert(!MQFilter.compile("$[9]").matches(array.toData()))

        // TreeSet：集合本身存在即真
        let set = TreeSet<Int64>()
        set.add(1)
        @Assert(MQFilter.compile("$").matches(set.toData()))

        // 空容器 + 空串过滤：恒为真
        let emptyFilter = MQFilter.compile("")
        @Assert(emptyFilter.matches(TreeSet<Int64>().toData()))
        @Assert(emptyFilter.matches(HashMap<String, Int64>().toData()))
        @Assert(emptyFilter.matches(Array<Int64>().toData()))
    }

    @TestCase
    public func invalidExpressionThrowsAtCompile(): Unit {
        var threw = false
        try {
            MQFilter.compile("order")
        } catch (_: Exception) {
            threw = true
        }
        @Assert(threw)
    }
}
