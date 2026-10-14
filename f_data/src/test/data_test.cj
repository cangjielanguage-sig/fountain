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
package fountain::f_data.test

import std.collection.*
import fountain::f_data.*
import fountain::f_data.macros.DataAssist
import std.unittest.*
import std.unittest.testmacro.*

@DataAssist[hash equal props fields tostring compare]
public class DataTest {
    private var i: Int64 = 0
    private var s: String = 'sdf'
    private var opts: ?String = None<String>
    private var dt: ?DataTest = None<DataTest>
    private var ilist: ArrayList<Int64> = ArrayList<Int64>([1, 2, 3, 4, 5])
    private var slist: ArrayList<String> = ArrayList<String>()
    private var dlist: ArrayList<DataTest> = ArrayList<DataTest>()
    private var dmap: HashMap<String, DataTest> = HashMap<String, DataTest>()
    private var tt: TT = TT()
}

@DataAssist[fields props]
public class TT {
    private var st: String = 'tttttt'
}

@Test
public class DataUnitTest {
    @TestCase
    public func test1(): Unit {
        var dt = DataTest()
        @Assert(dt is Hashable)
        @Assert(dt is Equatable<DataTest>)
        @Assert(dt is Comparable<DataTest>)
        dt.s = 'hello'
        @Assert('hello', dt.s)
        dt.s = 'hello world'
        let target = DataObject<DataTest>(DataTest())
        let data = (dt.toData() as DataObject<DataTest>).getOrThrow()
        println('-------------------------------------------------')
        let itr = data.iterator()
        for ((n, d) in itr) {
            println('${n} ${d}')
            target.set(n, d)
        }
        println('-------------------------------------------------')
        @Assert('hello world', target.data.s)
        dt = DataObject<DataTest>.populate(data).getOrThrow()
        @Assert('hello world', dt.s)
    }

    @TestCase
    public func testUncomparableFieldIsNotSilentlyEqual(): Unit {
        // DataTest.tt 的类型 TT 没有 Equatable：修复前 f_data_eq 兜底返回 true，
        // 两个字段完全相同的实例会被判相等（fail-open）；现在改为引用相等语义。
        let a = DataTest()
        let b = DataTest()
        @Assert(a == a)
        @Assert(!(a == b))
    }

    @TestCase
    public func testUnsupportedTryParseReturnsNone(): Unit {
        // tryParse 契约与其余 Data* 一致：不支持解析的类型返回 None（parse 仍抛异常）
        @Assert(DataList.tryParse('[]').isNone())
        @Assert(DataDict.tryParse('{}').isNone())
        @Assert(DataTuples.tryParse('[]').isNone())
    }

    @TestCase
    public func testDataToStringIsIdempotent(): Unit {
        // 修复前 toString() 每次都向 builder 追加 '}'，重复调用得到 `}}`
        let s = DataToString()
        s.append<DataTest>()
        s.append('i', 1)
        @Assert(s.toString(), s.toString())
    }
}
