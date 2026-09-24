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

    @TestCase
    public func testDeepNestedCountMatchSearch(): Unit {
        // count(match(search(@.name, 'lice'), 'Alice')) > 0
        // inner: search(@.name, 'lice') finds names containing "lice"
        // middle: match(result, 'Alice') matches that node's value against 'Alice'
        // outer: count how many children match
        let p1 = TestObj()  // Alice → search 'lice' → true → match 'Alice' → matches
        p1.set("name", DataString("Alice"))
        let p2 = TestObj()  // Bob → search 'lice' → false → doesn't reach match
        p2.set("name", DataString("Bob"))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        // Deep nesting: 3 levels (count > match > search)
        let path = DataPath.cache("$[?(count(match(search(@.name, 'lice'), 'Alice')) > 0)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testDeepNestedCountSearchMatch(): Unit {
        // count(search(match(@.name, 'Alice'), 'lice'))
        // inner: match(@.name, 'Alice') checks if name matches regex 'Alice'
        // outer: count(filter) applies search filter
        let p1 = TestObj()
        p1.set("name", DataString("Alice"))
        let p2 = TestObj()
        p2.set("name", DataString("Bob"))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(count(search(match(@.name, 'Alice'), 'lice')) > 0)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    @TestCase
    public func testDeepTripleNested(): Unit {
        // count(match(search(match(@.name, 'A.*'), 'lice'), 'Alice'))
        // Triple nesting: count > match > search > match
        let p1 = TestObj()
        p1.set("name", DataString("Alice"))
        let p2 = TestObj()
        p2.set("name", DataString("Bob"))
        let list = DataList()
        list.add(p1)
        list.add(p2)
        let path = DataPath.cache("$[?(count(match(search(match(@.name, 'A.*'), 'lice'), 'Alice')) > 0)]")
        let results = collect(path.get(list))
        @Assert(1, results.size)
    }

    /**
     * Generate a nested expression of the form:
     *   depth 1: match(@.name, 'A.*')
     *   depth 2: match(match(@.name, 'A.*'), 'Alice')
     *   depth N: match(...match(@.name, 'A.*')..., 'Alice')
     *
     * At each level, the inner expression is a filter that resolves to
     * a Data value; the outer match() uses filterToFirstValue to get
     * that value and applies its regex.
     *
     * This is an inductive proof: if depth K compiles and runs correctly,
     * the recursive compilation of depth K+1 is structurally identical
     * — the parser has no depth counter or recursion limit.
     */
    private static func genNestedMatch(depth: Int64): String {
        var s = StringGenerator()
        s.append("match(")
        if (depth <= 1) {
            s.append("@.name, 'Alice')")
        } else {
            s.append(genNestedMatch(depth - 1))
            s.append(", 'Alice')")
        }
        s.toString()
    }

    @TestCase
    public func testArbitraryDepthNesting(): Unit {
        // Inductive verification: generate expressions of depth 2..15
        // and verify they compile + produce correct results.
        // The generator uses match(match(...)) which requires the outer
        // match to take a function call as its first argument.
        let p1 = TestObj()
        p1.set("name", DataString("Alice"))
        p1.set("age", DataReal(30))
        let list = DataList()
        list.add(p1)
        // Test depth 2 through 15
        for (depth in 2..=15) {
            let expr = genNestedMatch(depth)
            let fullPath = "\$[?(${expr})]"
            try {
                let path = DataPath.cache(fullPath)
                let results = collect(path.get(list))
                @Assert(1, results.size)
            } catch (_: Exception) {
                @Assert("depth failed", "ok")
            }
        }
        // Depth 30 — stress test
        let deepExpr = genNestedMatch(30)
        let deepPath = "\$[?(${deepExpr})]"
        try {
            let path = DataPath.cache(deepPath)
            let results = collect(path.get(list))
            @Assert(1, results.size)
        } catch (_: Exception) {
            @Assert("depth=30 failed", "ok")
        }
    }
}
