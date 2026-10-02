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
