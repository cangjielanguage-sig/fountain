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
import std.collection.HashMap
import std.collection.ArrayList
import fountain::f_data.base.*

/**
 * A simple NamedData implementation for testing subpath access.
 * Avoids cyclic dependency with @DataAssist in f_data.macros.
 */
internal class TestObj <: Data & NamedData {
    private let map = HashMap<String, Data>()

    public func set(name: String, value: Data) {
        map[name] = value
    }
    public func get(name: String): ?Data {
        map.get(name)
    }
    public operator func [](name: String): Data {
        map.get(name).getOrThrow {DataException("field ${name} not found")}
    }
    public func toString(): String {
        let s = StringGenerator('{')
        var first = true
        for ((k, v) in map) {
            if (!first) {
                s.append(',')
            }
            first = false
            s.append('\"').append(k).append("\":").append(v.toString())
        }
        s.append('}').toString()
    }
    public static func fromData(data: Data, flag: DataConversionFlag): Any {
        throw DataException('TestObj.fromData not supported')
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        throw DataException('TestObj.tryFromData not supported')
    }
    public static func parse(s: String): Data {
        throw DataException('TestObj.parse not supported')
    }
    public static func tryParse(s: String): ?Data {
        None<Data>
    }
}

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
    public func testNegativeIndex(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[-1]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("30", results[0].toString())
    }

    @TestCase
    public func testNegativeIndexSecondLast(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$[-2]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("20", results[0].toString())
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
        let list = DataList()
        list.add(DataReal(10))
        let path = DataPath.cache("$[-100]")
        let results = collect(path.get(list))
        @Assert(0, results.size)
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

@Test
public class DataPath_filter_test {
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

    @TestCase
    public func testFilterEqString(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        let path = DataPath.cache("$[?(@.name == 'Alice')]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterEqInt(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        let path = DataPath.cache("$[?(@.age == 25)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterNotEq(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        let path = DataPath.cache("$[?(@.age != 30)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterLessThan(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        let path = DataPath.cache("$[?(@.age < 30)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterLessThanOrEqual(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let charlie = makePerson("Charlie", 35)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        list.add(charlie)
        let path = DataPath.cache("$[?(@.age <= 30)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterGreaterThan(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let charlie = makePerson("Charlie", 35)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        list.add(charlie)
        let path = DataPath.cache("$[?(@.age > 30)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterGreaterThanOrEqual(): Unit {
        let alice = makePerson("Alice", 30)
        let bob = makePerson("Bob", 25)
        let charlie = makePerson("Charlie", 35)
        let list = DataList()
        list.add(alice)
        list.add(bob)
        list.add(charlie)
        let path = DataPath.cache("$[?(@.age >= 30)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterAnd(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age >= 25 && @.age <= 30)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterOr(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age == 25 || @.age == 35)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterNot(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(!(@.age == 25))]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterIn(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age in [25, 35])]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterNin(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age nin [25, 35])]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterRegex(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.name =~ /A.*/)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterSize(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(@.name size 3)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }
}

@Test
public class DataPath_recursive_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    @TestCase
    public func testRecursiveDescentSimple(): Unit {
        let inner = DataList()
        inner.add(DataReal(1))
        inner.add(DataReal(2))
        let outer = DataList()
        outer.add(DataReal(0))
        outer.add(inner)
        outer.add(DataReal(3))
        // outer = [0, [1, 2], 3]
        // $..* should visit all descendants
        let path = DataPath.cache("$..*")
        let results = collect(path.get(outer))
        @Assert(true, results.size > 0)
    }

    @TestCase
    public func testFunctionMin(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(5))
        list.add(DataReal(20))
        let path = DataPath.cache("$.min()")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("5", results[0].toString())
    }

    @TestCase
    public func testFunctionMax(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(5))
        list.add(DataReal(20))
        let path = DataPath.cache("$.max()")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("20", results[0].toString())
    }

    @TestCase
    public func testFunctionLength(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$.length()")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("3", results[0].toString())
    }

    @TestCase
    public func testFunctionAvg(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$.avg()")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }
}

@Test
public class DataPath_compile_error_test {
    @TestCase
    public func testMissingRootDollar(): Unit {
        var ok = false
        try {
            DataPath.cache("x.y")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testUnclosedBracket(): Unit {
        var ok = false
        try {
            DataPath.cache("$[0")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testIllegalFunction(): Unit {
        var ok = false
        try {
            DataPath.cache("$.unknownFunc()")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }
}
