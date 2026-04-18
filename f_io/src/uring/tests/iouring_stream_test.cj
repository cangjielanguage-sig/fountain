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
package fountain::f_io.uring.tests

import std.unittest.testmacro.*
import std.fs.*
import fountain::f_base.*
import fountain::f_io.*

/**
 * IOUringStream 单元测试
 *
 * 使用临时文件验证基于 io_uring 的读写功能。
 */
@When[os == "Linux"]
@Test
public class IOUringStreamTest {

    private let tempDir: String = "/tmp/cj_uring_stream_test"

    /**
     * 创建临时目录和临时文件，返回 (文件路径, 已打开的可读写File)
     * File 在测试完成后由调用者关闭
     */
    private func createTempFile(): (String, File) {
        try {
            Directory.create(tempDir, recursive: true)
        } catch (_: FSException) {
            // 目录已存在，忽略
        }
        let tempFile = File.createTemp(tempDir)
        let path = tempFile.info.path.toString()
        tempFile.close()
        let rwFile = File(path, OpenMode.ReadWrite)
        (path, rwFile)
    }

    @TestCase
    public func testSimpleWriteAndRead(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            stream.write("hello io_uring".unsafeBytes())
        }

        let readFile = File(path, OpenMode.Read)
        let readFd = Int32(readFile.fileDescriptor.fileHandle)
        try(readStream = IOUringStream(readFd)) {
            let buf = Array<Byte>(64, repeat: 0)
            let n = readStream.read(buf)
            @Expect(n > 0)
            let content = String.fromUtf8(buf[0..Int64(n)])
            @Expect(content == "hello io_uring")
        }
        readFile.close()
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testReadEmptyBuffer(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            let emptyBuf = Array<Byte>(0, repeat: 0)
            let n = stream.read(emptyBuf)
            @Expect(n == 0)
        }
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testWriteEmptyBuffer(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            let emptyBuf = Array<Byte>(0, repeat: 0)
            stream.write(emptyBuf)
            @Expect(true)
        }
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testMultipleWrites(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            stream.write("part1_".unsafeBytes())
            stream.write("part2_".unsafeBytes())
            stream.write("part3".unsafeBytes())
        }

        let readFile = File(path, OpenMode.Read)
        let readFd = Int32(readFile.fileDescriptor.fileHandle)
        try(readStream = IOUringStream(readFd)) {
            let buf = Array<Byte>(64, repeat: 0)
            let n = readStream.read(buf)
            @Expect(n > 0)
            let content = String.fromUtf8(buf[0..Int64(n)])
            @Expect(content == "part1_part2_part3")
        }
        readFile.close()
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testSimpleConstructor(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            stream.write("simple".unsafeBytes())
        }

        let readFile = File(path, OpenMode.Read)
        let readFd = Int32(readFile.fileDescriptor.fileHandle)
        try(readStream = IOUringStream(readFd)) {
            let buf = Array<Byte>(32, repeat: 0)
            let n = readStream.read(buf)
            @Expect(n > 0)
            let content = String.fromUtf8(buf[0..Int64(n)])
            @Expect(content == "simple")
        }
        readFile.close()
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testFullConstructor(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd, 32, slotCount: 16)) {
            stream.write("full constructor".unsafeBytes())
        }

        let readFile = File(path, OpenMode.Read)
        let readFd = Int32(readFile.fileDescriptor.fileHandle)
        try(readStream = IOUringStream(readFd)) {
            let buf = Array<Byte>(64, repeat: 0)
            let n = readStream.read(buf)
            @Expect(n > 0)
            let content = String.fromUtf8(buf[0..Int64(n)])
            @Expect(content == "full constructor")
        }
        readFile.close()
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testLargeWriteAndRead(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            let data = Array<Byte>(4096) { i => UInt8(i % 256) }
            stream.write(data)
        }

        let readFile = File(path, OpenMode.Read)
        let readFd = Int32(readFile.fileDescriptor.fileHandle)
        try(readStream = IOUringStream(readFd)) {
            let buf = Array<Byte>(8192, repeat: 0)
            let n = readStream.read(buf)
            @Expect(n == 4096)
            var correct = true
            for (i in 0..4096) {
                if (buf[i] != UInt8(i % 256)) {
                    correct = false
                    break
                }
            }
            @Expect(correct)
        }
        readFile.close()
        file.close()
        removeIfExists(Path(path))
    }

    @TestCase
    public func testReadFromEmptyFile(): Unit {
        let (path, file) = createTempFile()
        let fd = Int32(file.fileDescriptor.fileHandle)
        try(stream = IOUringStream(fd)) {
            let buf = Array<Byte>(64, repeat: 0)
            let n = stream.read(buf)
            @Expect(n <= 0)
        }
        file.close()
        removeIfExists(Path(path))
    }
}
