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

@When[os == "Linux"]
func doCreateStoreStreamLinux(testDir: String): Unit {
    let path = "${testDir}/test_iouring_io.sst"
    Directory.create(testDir, recursive: true)
    let file = File(path, OpenMode.ReadWrite) // 保持 File 存活
    let stream = IOUringStream(Int32(file.fileDescriptor.fileHandle), 64)
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
    let stream = File(path, OpenMode.ReadWrite)
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
