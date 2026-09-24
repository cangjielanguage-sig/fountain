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
