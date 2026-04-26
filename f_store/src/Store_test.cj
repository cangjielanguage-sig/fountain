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
import std.fs.{File, OpenMode, Directory, remove}
import std.collection.ArrayList

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
        @Expect(v.value.isSome())
        @Expect(v.sequence == 1)
        @Expect(v.expireAt.isNone())
    }

    @TestCase
    public func entryValueWithExpireAt(): Unit {
        let v = EntryValue([0x01], 2, expireAt: 1000000)
        @Expect(v.value.isSome())
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
        @Expect(v.value.isNone())
        @Expect(v.sequence == 3)
        @Expect(v.expireAt.isNone())
    }

    @TestCase
    public func storeClosedException(): Unit {
        let e = StoreClosedException()
        @Expect(e.message == "Store is closed")
    }
}

@When[os == "Linux"]
func doCreateStoreStreamLinux(testDir: String): Unit {
    let path = "${testDir}/test_iouring_io.sst"
    Directory.create(testDir, recursive: true)
    let file = File(path, OpenMode.ReadWrite) // 保持 File 存活
    let stream = createStoreStream(path, OpenMode.ReadWrite)
    stream.write([0x01, 0x02, 0x03])
    stream.flush()
    (stream as Resource)?.close()
    file.close()
    // 验证文件内容
    let readFile = File(path, OpenMode.Read)
    let buf = Array<Byte>(3, repeat: 0u8)
    let n = readFile.read(buf)
    readFile.close()
    @Expect(n == 3)
    @Expect(buf[0] == 0x01)
    @Expect(buf[1] == 0x02)
    @Expect(buf[2] == 0x03)
    // 清理
    remove(path)
    remove(testDir, recursive: true)
}

@When[os != "Linux"]
func doCreateStoreStreamNonLinux(testDir: String): Unit {
    let path = "${testDir}/test_file_io.sst"
    Directory.create(testDir, recursive: true)
    let stream = createStoreStream(path, OpenMode.ReadWrite)
    stream.write([0x01, 0x02, 0x03])
    stream.flush()
    (stream as Resource)?.close()
    // 验证文件内容
    let file = File(path, OpenMode.Read)
    let buf = Array<Byte>(3, repeat: 0u8)
    let n = file.read(buf)
    file.close()
    @Expect(n == 3)
    @Expect(buf[0] == 0x01)
    @Expect(buf[1] == 0x02)
    @Expect(buf[2] == 0x03)
    // 清理
    remove(path)
    remove(testDir, recursive: true)
}

@When[os == "Linux"]
func doCreateStoreStreamNonLinux(testDir: String): Unit {
    // Linux 下非 Linux 版本为空操作
}

@When[os != "Linux"]
func doCreateStoreStreamLinux(testDir: String): Unit {
    // 非 Linux 下 Linux 版本为空操作
}

@Test
public class StoreStep2Test {

    let testDir = "/tmp/f_store_step2_test"

    @TestCase
    public func createStoreStreamWriteReadFlushClose(): Unit {
        doCreateStoreStreamLinux(testDir)
        doCreateStoreStreamNonLinux(testDir)
    }
}

@Test
public class StoreStep3Test {

    @TestCase
    public func memTableAddAndGet(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x02]), EntryValue([0x0B], 2))
        let v1 = mt.get(ByteArray([0x01]))
        let v2 = mt.get(ByteArray([0x02]))
        let v3 = mt.get(ByteArray([0x03]))
        @Expect(v1.isSome())
        @Expect(v2.isSome())
        @Expect(v3.isNone())
        if (let Some(e) <- v1) {
            @Expect(e.sequence == 1)
        }
        if (let Some(e) <- v2) {
            @Expect(e.sequence == 2)
        }
    }

    @TestCase
    public func memTableAddOverwrite(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        let old = mt.add(ByteArray([0x01]), EntryValue([0x0B], 2))
        // 旧值应返回
        if (let Some(e) <- old) {
            @Expect(e.sequence == 1)
        } else {
            @Assert(false)
        }
        // get 返回新值
        let cur = mt.get(ByteArray([0x01]))
        if (let Some(e) <- cur) {
            @Expect(e.sequence == 2)
        }
    }

    @TestCase
    public func memTableIteratorOrdered(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x03]), EntryValue(None, 3))
        mt.add(ByteArray([0x01]), EntryValue(None, 1))
        mt.add(ByteArray([0x02]), EntryValue(None, 2))
        let iter = mt.iterator()
        let keys = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter.next()) {
            keys.add(k)
        }
        @Expect(keys.size == 3)
        @Expect(keys[0] == ByteArray([0x01]))
        @Expect(keys[1] == ByteArray([0x02]))
        @Expect(keys[2] == ByteArray([0x03]))
    }

    @TestCase
    public func memTableTailer(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue(None, 1))
        mt.add(ByteArray([0x02]), EntryValue(None, 2))
        mt.add(ByteArray([0x03]), EntryValue(None, 3))
        mt.add(ByteArray([0x04]), EntryValue(None, 4))
        let iter = mt.tailer(ByteArray([0x02]))
        let keys = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter.next()) {
            keys.add(k)
        }
        @Expect(keys.size == 3)
        @Expect(keys[0] == ByteArray([0x02]))
        @Expect(keys[1] == ByteArray([0x03]))
        @Expect(keys[2] == ByteArray([0x04]))
    }

    @TestCase
    public func memTableApproximateSize(): Unit {
        let mt = MemTable()
        @Expect(mt.approximateSize() == 0)
        mt.add(ByteArray([0x01, 0x02]), EntryValue([0x0A, 0x0B], 1))
        @Expect(mt.approximateSize() > 0)
    }
}
