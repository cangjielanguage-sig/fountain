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
