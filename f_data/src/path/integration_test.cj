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
