/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_store

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.ArrayList

@Test
public class ByteArrayEntryValueTest {

    @TestCase
    public func byteArrayEmptyEqual(): Unit {
        let a = ByteArray(Array<Byte>())
        let b = ByteArray(Array<Byte>())
        @Expect(a == b)
        @Expect(!(a != b))
        @Expect(a.compare(b) == EQ)
    }

    @TestCase
    public func byteArrayPrefixIsLess(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x01, 0x02, 0x03])
        @Expect(a < b)
        @Expect(a.compare(b) == LT)
        @Expect(b.compare(a) == GT)
    }

    @TestCase
    public func byteArrayDifferentByte(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x01, 0x03])
        @Expect(a < b)
        @Expect(a.compare(b) == LT)
    }

    @TestCase
    public func byteArrayEqual(): Unit {
        let a = ByteArray([0x01, 0x02, 0x03])
        let b = ByteArray([0x01, 0x02, 0x03])
        @Expect(a == b)
        @Expect(a.compare(b) == EQ)
    }

    @TestCase
    public func byteArrayNotEqual(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x01, 0x03])
        @Expect(a != b)
    }

    @TestCase
    public func byteArrayClone(): Unit {
        let a = ByteArray([0x01, 0x02, 0x03])
        let b = a  // ByteArray 是值类型 struct，赋值即拷贝
        @Expect(a == b)
    }

    @TestCase
    public func byteArrayToArray(): Unit {
        let a = ByteArray([0x01, 0x02, 0x03])
        let arr = a.bytes
        @Expect(arr == [0x01, 0x02, 0x03])
    }

    @TestCase
    public func entryValueDefaultFields(): Unit {
        let ev = EntryValue([0x0A], 1)
        @Expect(ev.value == [0x0A])
        @Expect(ev.sequence == 1)
        @Expect(ev.expireAt.isNone())
    }

    @TestCase
    public func entryValueWithExpireAt(): Unit {
        let ev = EntryValue([0x0A], 1, expireAt: 1000)
        @Expect(ev.expireAt.isSome())
    }

    @TestCase
    public func entryValueTombstone(): Unit {
        let ev = EntryValue(None, 1)
        @Expect(ev.value.isNone())
    }
}