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
