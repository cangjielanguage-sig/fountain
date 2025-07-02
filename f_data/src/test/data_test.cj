/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.test

import std.collection.*
import f_data.*
import f_data.macros.DataAssist
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
}
