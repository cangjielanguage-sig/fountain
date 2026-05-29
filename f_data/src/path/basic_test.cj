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
package fountain::f_data.path

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import fountain::f_data.base.*
import fountain::f_data.exception.DataException

@Test
public class DataPath_basic_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    private func makePerson(name: String, age: Int64): TestObj {
        let obj = TestObj()
        obj.set("name", DataString(name))
        obj.set("age", DataReal(age))
        obj
    }

    // Helper: assert a data value's toString equals expected string
    private func assertDataStr(expected: String, data: Data): Bool {
        data.toString() == expected
    }

    @TestCase
    public func testRootPath(): Unit {
        let d: Data = DataReal(42)
        let path = DataPath.cache("$")
        let results = collect(path.get(d))
        @Assert(1, results.size)
        @Assert("42", results[0].toString())
    }

    @TestCase
    public func testSubPath(): Unit {
        let obj = makePerson("Alice", 30)
        let path = DataPath.cache("$.name")
        let results = collect(path.get(obj))
        @Assert(1, results.size)
        @Assert("Alice", results[0].toString())
    }

    @TestCase
    public func testMultiSubPath(): Unit {
        let obj = makePerson("Bob", 25)
        let path = DataPath.cache("$['name','age']")
        let results = collect(path.get(obj))
        @Assert(2, results.size)
    }

    @TestCase
    public func testIndex(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[0]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("10", results[0].toString())
    }

    @TestCase
    public func testIndexSecond(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[1]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("20", results[0].toString())
    }

    @TestCase
    public func testNegativeIndexThrows(): Unit {
        var ok = false
        try {
            DataPath.cache("$[-1]")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testNegativeIndexSecondLastThrows(): Unit {
        var ok = false
        try {
            DataPath.cache("$[-2]")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testMultiIndex(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[0,2]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
        @Assert("10", results[0].toString())
        @Assert("30", results[1].toString())
    }

    @TestCase
    public func testRange(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        list.add(DataReal(40))
        list.add(DataReal(50))
        let path = DataPath.cache("$[1:4]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
        @Assert("20", results[0].toString())
        @Assert("30", results[1].toString())
        @Assert("40", results[2].toString())
    }

    @TestCase
    public func testRangeWithStep(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        list.add(DataReal(40))
        list.add(DataReal(50))
        let path = DataPath.cache("$[0:5:2]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
        @Assert("10", results[0].toString())
        @Assert("30", results[1].toString())
        @Assert("50", results[2].toString())
    }

    @TestCase
    public func testRangeEmptyStartBeyondEnd(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[5:10]")
        let results = collect(path.get(list))
        @Assert(0, results.size)
    }

    @TestCase
    public func testSliceDefaultStart(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        list.add(DataReal(40))
        list.add(DataReal(50))
        let path = DataPath.cache("$[:3]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
        @Assert("10", results[0].toString())
        @Assert("20", results[1].toString())
        @Assert("30", results[2].toString())
    }

    @TestCase
    public func testSliceDefaultEnd(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        list.add(DataReal(40))
        list.add(DataReal(50))
        let path = DataPath.cache("$[3:]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
        @Assert("40", results[0].toString())
        @Assert("50", results[1].toString())
    }

    @TestCase
    public func testSliceDefaultAll(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[:]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
    }

    @TestCase
    public func testSliceReverse(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        list.add(DataReal(40))
        list.add(DataReal(50))
        let path = DataPath.cache("$[::-1]")
        let results = collect(path.get(list))
        @Assert(5, results.size)
        @Assert("50", results[0].toString())
        @Assert("40", results[1].toString())
        @Assert("30", results[2].toString())
        @Assert("20", results[3].toString())
        @Assert("10", results[4].toString())
    }

    @TestCase
    public func testSliceStepZero(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[0:3:0]")
        let results = collect(path.get(list))
        @Assert(0, results.size)
    }

    @TestCase
    public func testWildcard(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[*]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
    }

    @TestCase
    public func testSubPathNotFound(): Unit {
        let obj = makePerson("Alice", 30)
        let path = DataPath.cache("$.nonexistent")
        let results = collect(path.get(obj))
        @Assert(0, results.size)
    }

    @TestCase
    public func testOutOfRangeIndex(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        let path = DataPath.cache("$[100]")
        let results = collect(path.get(list))
        @Assert(0, results.size)
    }

    @TestCase
    public func testNegativeIndexOutOfRange(): Unit {
        var ok = false
        try {
            DataPath.cache("$[-100]")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testSolidCompile(): Unit {
        let path1 = DataPath.solid("$.name")
        let path2 = DataPath.solid("$.name")
        let obj = TestObj()
        obj.set("name", DataString("test"))
        @Assert(1, collect(path1.get(obj)).size)
        @Assert(1, collect(path2.get(obj)).size)
    }
}
