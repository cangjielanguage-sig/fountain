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
    public func testFilterRegexFullMatch(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        // A.+ fully matches "Alice" but not "Bob" or "Charlie"
        let path = DataPath.cache("$[?(@.name =~ /A.+/)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterRegexSubstring(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        // Cangjie Regex.matches does substring search, "lice" matches "Alice" but not "Bob"/"Charlie"
        let path = DataPath.cache("$[?(@.name =~ /lice/)]")
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

    @TestCase
    public func testFilterExists(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = TestObj()
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)  // p3 has no name set
        let path = DataPath.cache("$[?(@.name)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterExistsAnd(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = TestObj()
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.name && @.age)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterNotExists(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = TestObj()
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(!(@.name))]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterNullEq(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        p3.set("name", DataNone.INSTANCE)  // Set name to null explicitly
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.name == null)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterNullNotEq(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        p3.set("name", DataNone.INSTANCE)  // Set name to null explicitly
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.name != null)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterMatch(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(match(@.name, 'Alice'))]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterSearch(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        // "lice" only matches "Alice", not "Bob" or "Charlie"
        let path = DataPath.cache("$[?(search(@.name, 'lice'))]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterCountEq(): Unit {
        // Test: count(@.*) == 3 on a list with 3 elements
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = TestObj()
        // Wrap them in sub-lists with different sizes
        let l3 = DataList()  // 3 elements
        l3.add(p1); l3.add(p2); l3.add(p3)
        let l1 = DataList()  // 1 element
        l1.add(p1)
        let outer = DataList()
        outer.add(l1)
        outer.add(l3)
        let path = DataPath.cache("$[?(count(@.*) == 3)]")
        let results = collect(path.get(outer))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterValueEq(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        // value(@.name) extracts the first matching node's value as string
        // We use @.name which returns the "name" field
        let path = DataPath.cache("$[?(value(@.name) == 'Alice')]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterLengthGt(): Unit {
        let p1 = makePerson("Alice", 30)  // name length = 5
        let p2 = makePerson("Bob", 25)    // name length = 3
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(length(@.name) > 3)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterArrayEq(): Unit {
        let l1 = DataList()
        l1.add(DataReal(1)); l1.add(DataReal(2)); l1.add(DataReal(3))
        let l2 = DataList()
        l2.add(DataReal(4)); l2.add(DataReal(5))
        let outer = DataList()
        outer.add(l1)
        outer.add(l2)
        let path = DataPath.cache("$[?(@.* == [1, 2, 3])]")
        let results = collect(path.get(outer))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterArrayNotEq(): Unit {
        let l1 = DataList()
        l1.add(DataReal(1)); l1.add(DataReal(2)); l1.add(DataReal(3))
        let l2 = DataList()
        l2.add(DataReal(4)); l2.add(DataReal(5))
        let outer = DataList()
        outer.add(l1)
        outer.add(l2)
        let path = DataPath.cache("$[?(@.* != [1, 2, 3])]")
        let results = collect(path.get(outer))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterCountNotEq(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let l3 = DataList()
        l3.add(p1); l3.add(p2); l3.add(TestObj())
        let l1 = DataList()
        l1.add(p1)
        let outer = DataList()
        outer.add(l1)
        outer.add(l3)
        let path = DataPath.cache("$[?(count(@.*) != 3)]")
        let results = collect(path.get(outer))
        @Assert(1, results.size)  // l1 has 1 element, not 3
    }

    @TestCase
    public func testFilterMatchOrCmp(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        // match(@.name, "Alice") || @.age > 30 → Alice matches, Charlie has age=35
        let path = DataPath.cache("$[?(match(@.name, 'Alice') || @.age > 30)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterInNull(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        p3.set("name", DataNone.INSTANCE)  // Charlie's name is null
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.name in [null, 'Bob'])]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterNinNull(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        p3.set("name", DataNone.INSTANCE)  // Charlie's name is null
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.name nin [null, 'Bob'])]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterEqFloat(): Unit {
        let p1 = makePerson("Alice", 30)
        p1.set("price", DataReal("3.14"))
        let p2 = makePerson("Bob", 25)
        p2.set("price", DataReal("2.71"))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(@.price == 3.14)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterEqBool(): Unit {
        let p1 = makePerson("Alice", 30)
        p1.set("active", DataBool.TRUE)
        let p2 = makePerson("Bob", 25)
        p2.set("active", DataBool.FALSE)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(@.active == true)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterAnyOf(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age anyof [25, 35])]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterSubSetOf(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age subsetof [25, 30, 35])]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
    }

    @TestCase
    public func testFilterNoOneOf(): Unit {
        let p1 = makePerson("Alice", 30)
        let p2 = makePerson("Bob", 25)
        let p3 = makePerson("Charlie", 35)
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(@.age nooneof [40, 50])]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
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
        // RFC §2.5.2: bare $.. without selector throws DataException
        var ok = false
        try {
            DataPath.cache("$..")
        } catch (_: DataException) {
            ok = true
        }
        @Assert(true, ok)
    }

    @TestCase
    public func testRecursiveDescentAll(): Unit {
        // Use $..* for all descendants (RFC compliant)
        let inner = DataList()
        inner.add(DataReal(1))
        inner.add(DataReal(2))
        let outer = DataList()
        outer.add(DataReal(0))
        outer.add(inner)
        outer.add(DataReal(3))
        let path = DataPath.cache("$..*")
        let results = collect(path.get(outer))
        @Assert(true, results.size > 0)
    }

    @TestCase
    public func testRecursiveDescendStar(): Unit {
        let inner = DataList()
        inner.add(DataReal(1))
        inner.add(DataReal(2))
        let outer = DataList()
        outer.add(DataReal(0))
        outer.add(inner)
        outer.add(DataReal(3))
        let path = DataPath.cache("$..*")
        let results = collect(path.get(outer))
        @Assert(true, results.size > 0)
    }

    @TestCase
    public func testRecursiveDescendSubPath(): Unit {
        let p1 = TestObj()
        p1.set("val", DataReal(42))
        let p2 = TestObj()
        p2.set("val", DataReal(99))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$..val")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testRecursiveBracketName(): Unit {
        let p1 = TestObj()
        p1.set("val", DataReal(42))
        let p2 = TestObj()
        p2.set("val", DataReal(99))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$..['val']")
        let results = collect(path.get(list))
        @Assert(2, results.size)
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
    public func testFunctionCount(): Unit {
        let list = DataList()
        list.add(DataReal(10))
        list.add(DataReal(20))
        list.add(DataReal(30))
        let path = DataPath.cache("$.count()")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("3", results[0].toString())
    }

    @TestCase
    public func testFunctionValue(): Unit {
        let list = DataReal(42)
        let path = DataPath.cache("$.value()")
        let results = collect(path.get(list))
        @Assert(1, results.size)
        @Assert("42", results[0].toString())
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

@Test
public class DataPath_object_eq_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    @TestCase
    public func testFilterObjectEq(): Unit {
        let obj1 = DataDict()
        obj1.add("name", DataString("Alice"))
        obj1.add("age", DataReal(30))
        let obj2 = DataDict()
        obj2.add("name", DataString("Bob"))
        obj2.add("age", DataReal(25))
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        let path = DataPath.cache("$[?(@ == {\"name\": \"Alice\", \"age\": 30})]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterObjectNotEq(): Unit {
        let obj1 = DataDict()
        obj1.add("name", DataString("Alice"))
        obj1.add("age", DataReal(30))
        let obj2 = DataDict()
        obj2.add("name", DataString("Bob"))
        obj2.add("age", DataReal(25))
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        let path = DataPath.cache("$[?(@ != {\"name\": \"Bob\", \"age\": 25})]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterObjectEqNestedArray(): Unit {
        let inner = DataList()
        inner.add(DataReal(1))
        inner.add(DataReal(2))
        inner.add(DataReal(3))
        let obj1 = DataDict()
        obj1.add("name", DataString("Alice"))
        obj1.add("tags", inner)
        let obj2 = DataDict()
        obj2.add("name", DataString("Bob"))
        obj2.add("tags", DataList())
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        let path = DataPath.cache("$[?(@ == {\"name\": \"Alice\", \"tags\": [1, 2, 3]})]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterObjectEqNestedObject(): Unit {
        let addr = DataDict()
        addr.add("city", DataString("NYC"))
        addr.add("zip", DataReal(10001))
        let obj1 = DataDict()
        obj1.add("name", DataString("Alice"))
        obj1.add("address", addr)
        let obj2 = DataDict()
        obj2.add("name", DataString("Bob"))
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        let path = DataPath.cache("$[?(@ == {\"name\": \"Alice\", \"address\": {\"city\": \"NYC\", \"zip\": 10001}})]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testFilterObjectEqBoolAndNull(): Unit {
        let obj1 = DataDict()
        obj1.add("active", DataBool.TRUE)
        obj1.add("extra", DataNone.INSTANCE)
        let obj2 = DataDict()
        obj2.add("active", DataBool.FALSE)
        obj2.add("extra", DataString("something"))
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        let path = DataPath.cache("$[?(@ == {\"active\": true, \"extra\": null})]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }
}

@Test
public class DataPath_complex_fn_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    private func makeObj(name: String, age: Int64, pattern: String): TestObj {
        let obj = TestObj()
        obj.set("name", DataString(name))
        obj.set("age", DataReal(age))
        obj.set("pattern", DataString(pattern))
        obj
    }

    @TestCase
    public func testDeferredMatchField(): Unit {
        let obj1 = makeObj("Alice", 30, "^A")
        let obj2 = makeObj("Bob", 25, "^B")
        let obj3 = makeObj("Charlie", 35, "^C")
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        list.add(obj3)
        let path = DataPath.cache("$[?(match(@.name, @.pattern))]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
    }

    @TestCase
    public func testDeferredSearchField(): Unit {
        let obj1 = makeObj("Alice", 30, "li")
        let obj2 = makeObj("Bob", 25, "ob")
        let obj3 = makeObj("Charlie", 35, "xyz")
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        list.add(obj3)
        let path = DataPath.cache("$[?(search(@.name, @.pattern))]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testCountMatch(): Unit {
        let p1 = TestObj()
        p1.set("name", DataString("Alice"))
        let p2 = TestObj()
        p2.set("name", DataString("Alice"))
        let p3 = TestObj()
        p3.set("name", DataString("Bob"))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        let path = DataPath.cache("$[?(count(match(@.name, 'Alice')) > 0)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testCountSearch(): Unit {
        let obj1 = TestObj()
        obj1.set("name", DataString("Alice"))
        obj1.set("extra", DataString("foo"))
        let obj2 = TestObj()
        obj2.set("name", DataString("Bob"))
        obj2.set("extra", DataString("foo"))
        let obj3 = TestObj()
        obj3.set("name", DataString("Charlie"))
        obj3.set("extra", DataString("bar"))
        let list = DataList()
        list.add(obj1)
        list.add(obj2)
        list.add(obj3)
        let path = DataPath.cache("$[?(count(search(@.extra, 'foo')) == 1)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }
}

@Test
public class DataPath_integration_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    private func buildStore(): TestObj {
        // Build a deeply nested store structure:
        // store
        // ├── name: "Bookstore"
        // ├── books
        // │   ├── { title: "The Great Gatsby", author: "F. Scott Fitzgerald", price: 10.99 }
        // │   └── { title: "1984", author: "George Orwell", price: 8.99 }
        // └── employees
        //     ├── alice: { role: "manager", age: 35 }
        //     └── bob: { role: "clerk", age: 28 }

        let book1 = TestObj()
        book1.set("title", DataString("The Great Gatsby"))
        book1.set("author", DataString("F. Scott Fitzgerald"))
        book1.set("price", DataReal("10.99"))

        let book2 = TestObj()
        book2.set("title", DataString("1984"))
        book2.set("author", DataString("George Orwell"))
        book2.set("price", DataReal("8.99"))

        let books = DataList()
        books.add(book1)
        books.add(book2)

        let alice = TestObj()
        alice.set("role", DataString("manager"))
        alice.set("age", DataReal(35))

        let bob = TestObj()
        bob.set("role", DataString("clerk"))
        bob.set("age", DataReal(28))

        let employees = TestObj()
        employees.set("alice", alice)
        employees.set("bob", bob)

        let store = TestObj()
        store.set("name", DataString("Bookstore"))
        store.set("books", books)
        store.set("employees", employees)
        store
    }

    @TestCase
    public func testNestedSimpleProperty(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.name")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("Bookstore", results[0].toString())
    }

    @TestCase
    public func testNestedArrayIndex(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.books[0].title")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("The Great Gatsby", results[0].toString())
    }

    @TestCase
    public func testNestedArrayIndexSecond(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.books[1].author")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("George Orwell", results[0].toString())
    }

    @TestCase
    public func testNestedWildcardProperty(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.books[*].title")
        let results = collect(path.get(store))
        @Assert(2, results.size)
    }

    @TestCase
    public func testRecursiveDescentTitle(): Unit {
        // Recursive descent requires Iterable root; use DataList wrapper
        let book1 = TestObj()
        book1.set("title", DataString("The Great Gatsby"))
        let book2 = TestObj()
        book2.set("title", DataString("1984"))
        let list = DataList()
        list.add(book1)
        list.add(book2)
        let path = DataPath.cache("$..title")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testFilterOnNestedArray(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.books[?(@.price > 9)].title")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("The Great Gatsby", results[0].toString())
    }

    @TestCase
    public func testNestedObjectAccess(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.employees.bob.age")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("28", results[0].toString())
    }

    @TestCase
    public func testCombinedSliceFilter(): Unit {
        let store = buildStore()
        let path = DataPath.cache("$.books[?(@.price < 10)].title")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("1984", results[0].toString())
    }

    @TestCase
    public func testRecursiveDescentBooks(): Unit {
        // Use DataList root for recursive descent (requires Iterable root)
        let book1 = TestObj()
        book1.set("title", DataString("The Great Gatsby"))
        let book2 = TestObj()
        book2.set("title", DataString("1984"))
        let list = DataList()
        list.add(book1)
        list.add(book2)
        let path = DataPath.cache("$..title")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testMultiFieldFilter(): Unit {
        let store = buildStore()
        // Combined filter: price > 9 AND author != 'George Orwell'
        let path = DataPath.cache("$.books[?(@.price > 9 && @.author != 'George Orwell')].title")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("The Great Gatsby", results[0].toString())
    }

    @TestCase
    public func testNegativeIndexSlice(): Unit {
        let store = buildStore()
        // Use slice syntax for negative index (RFC §2.3.4)
        let path = DataPath.cache("$.books[-1:].title")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("1984", results[0].toString())
    }

    @TestCase
    public func testMultipleFilters(): Unit {
        let store = buildStore()
        // Two chained filters: price > 0 then price < 10
        let path = DataPath.cache("$.books[?(@.price > 0)][?(@.price < 10)].title")
        let results = collect(path.get(store))
        @Assert(1, results.size)
        @Assert("1984", results[0].toString())
    }
}

@Test
public class DataPath_p1_gaps_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    private func makePerson(name: String, age: Int64, role: String): TestObj {
        let obj = TestObj()
        obj.set("name", DataString(name))
        obj.set("age", DataReal(age))
        obj.set("role", DataString(role))
        obj
    }

    @TestCase
    public func testPathEq(): Unit {
        let p1 = makePerson("Alice", 30, "admin")
        let p2 = makePerson("Bob", 25, "admin")
        let p3 = makePerson("Charlie", 35, "user")
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        // filter: @.role == @.role (always true)
        let path = DataPath.cache("$[?(@.role == @.role)]")
        let results = collect(path.get(list))
        @Assert(3, results.size)
    }

    @TestCase
    public func testPathNotEq(): Unit {
        let p1 = makePerson("Alice", 30, "admin")
        let p2 = makePerson("Bob", 25, "user")
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(@.role != @.name)]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testPathEqFiltered(): Unit {
        let p1 = makePerson("Alice", 30, "admin")
        let p2 = makePerson("Bob", 25, "user")
        let p3 = makePerson("Charlie", 35, "admin")
        let list = DataList()
        list.add(p1)
        list.add(p2)
        list.add(p3)
        // People whose role matches the 'admin' person
        let path = DataPath.cache("$[?(@.role == 'admin')]")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testEscapeBracketName(): Unit {
        let obj = TestObj()
        obj.set("key", DataString("val"))
        let list = DataList()
        list.add(obj)
        let path = DataPath.cache("$..['key']")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testMultipleBracketSelectors(): Unit {
        let obj = TestObj()
        obj.set("first", DataString("1"))
        obj.set("second", DataString("2"))
        let list = DataList()
        list.add(obj)
        let path = DataPath.cache("$..['first','second']")
        let results = collect(path.get(list))
        @Assert(2, results.size)
    }

    @TestCase
    public func testBracketName(): Unit {
        let obj = TestObj()
        obj.set("myname", DataString("test"))
        let list = DataList()
        list.add(obj)
        let path = DataPath.cache("$..['myname']")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }
}
