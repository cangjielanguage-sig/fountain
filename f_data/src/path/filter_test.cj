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
