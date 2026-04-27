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
public class WALRecordTest {

    @TestCase
    public func walRecordEncodeDecodeRoundTrip(): Unit {
        let key: Array<Byte> = [0x01, 0x02, 0x03]
        let value: Array<Byte> = [0x0A, 0x0B]
        let record = WALRecord(42, key, Some(value))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 42)
            @Expect(r.key == key)
            @Expect(r.value.isSome())
            if (let Some(v) <- r.value) {
                @Expect(v == value)
            }
            @Expect(r.expireAt.isNone())
        }
    }

    @TestCase
    public func walRecordTombstone(): Unit {
        let key: Array<Byte> = [0x01]
        let record = WALRecord(1, key, None)
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 1)
            @Expect(r.key == key)
            @Expect(r.value.isNone())
            @Expect(r.expireAt.isNone())
        }
    }

    @TestCase
    public func walRecordWithExpireAt(): Unit {
        let key: Array<Byte> = [0x01]
        let value: Array<Byte> = [0x0A]
        let expireAt: Int64 = 1000000000
        let record = WALRecord(2, key, Some(value), expireAt: expireAt)
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 2)
            @Expect(r.expireAt.isSome())
            if (let Some(ea) <- r.expireAt) {
                @Expect(ea == expireAt)
            }
        }
    }

    @TestCase
    public func walRecordEmptyValues(): Unit {
        let key: Array<Byte> = []
        let value: Array<Byte> = []
        let record = WALRecord(3, key, Some(value))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.key.size == 0)
            @Expect(r.value.isSome())
            if (let Some(v) <- r.value) {
                @Expect(v.size == 0)
            }
        }
    }

    @TestCase
    public func walRecordLargeKeyValue(): Unit {
        let key = Array<Byte>(1000, repeat: 0xABu8)
        let value = Array<Byte>(5000, repeat: 0xCDu8)
        let record = WALRecord(8, key, Some(value))
        let encoded = record.encode()
        let decoded = WALRecord.decode(encoded)
        @Expect(decoded.isSome())
        if (let Some(r) <- decoded) {
            @Expect(r.sequence == 8)
            @Expect(r.key.size == 1000)
            @Expect(r.value.isSome())
            if (let Some(v) <- r.value) {
                @Expect(v.size == 5000)
            }
        }
    }
}