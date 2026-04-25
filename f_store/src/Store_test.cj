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

@Test
public class StoreStep1Test {

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
    public func byteArrayHashCodeEqual(): Unit {
        let a = ByteArray([0x01, 0x02, 0x03])
        let b = ByteArray([0x01, 0x02, 0x03])
        @Expect(a.hashCode() == b.hashCode())
    }

    @TestCase
    public func byteArrayHashCodeDifferent(): Unit {
        let a = ByteArray([0x01, 0x02])
        let b = ByteArray([0x03, 0x04])
        @Expect(a.hashCode() != b.hashCode())
    }

    @TestCase
    public func entryValueBasic(): Unit {
        let v = EntryValue([0x01, 0x02], 1)
        @Expect(v.value != None)
        @Expect(v.sequence == 1)
        @Expect(v.expireAt == None)
    }

    @TestCase
    public func entryValueWithExpireAt(): Unit {
        let v = EntryValue([0x01], 2, expireAt: 1000000)
        @Expect(v.value != None)
        @Expect(v.sequence == 2)
        if (let Some(ea) <- v.expireAt) {
            @Expect(ea == 1000000)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func entryValueTombstone(): Unit {
        let v = EntryValue(None, 3)
        @Expect(v.value == None)
        @Expect(v.sequence == 3)
        @Expect(v.expireAt == None)
    }

    @TestCase
    public func storeClosedException(): Unit {
        let e = StoreClosedException()
        @Expect(e.message == "Store is closed")
    }
}
