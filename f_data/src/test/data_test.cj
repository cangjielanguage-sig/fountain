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


@DataAssist[fields props]
public class TT{
    private var s: String = ''
}
@DataAssist[hash equal props fields]
public class DataTest {
  private var i: Int64 = 0
  private var s: String = ''
//   private var opts: ?String = None
  private var tt: TT = TT()
  private var ilist: ArrayList<Int64> = ArrayList<Int64>()
  private var slist: ArrayList<String> = ArrayList<String>()
  private var dlist: ArrayList<DataTest> = ArrayList<DataTest>()
  private var dmap: HashMap<String, DataTest> = HashMap<String, DataTest>()
}
@Test
public class DataUnitTest {
    @TestCase
    public func test1(): Unit {
        let dt = DataTest()
        @Assert(dt is Hashable)
        @Assert(dt is Equatable<DataTest>)
        @Assert(!(dt is Comparable<DataTest>))
        dt.s = 'hello'
        @Assert('hello', dt.s)
    }
}