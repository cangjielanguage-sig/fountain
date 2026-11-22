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
package fountain::f_http

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.UnsafeBytes
import fountain::f_data.*
import fountain::f_http.exception.MultipartException
import fountain::f_io.ByteBuffer

/**
 * `MultipartFormDataParser.parse` 的回归套件（`f_http` 首批测试）。
 *
 * 只走公开 API（构造 + `parse()`），不碰私有成员；用例先于「缓冲复用」实现落地，
 * 用来锁住现状的可观察行为：返回的 `Data`、分支结果、异常类型。
 */

private const TEST_BOUNDARY: String = "----fountainTestBoundary"
private func formDataMediaType(): String {
    "multipart/form-data; boundary=${TEST_BOUNDARY}"
}

private func mixedMediaType(): String {
    "multipart/mixed; boundary=${TEST_BOUNDARY}"
}

/** `RotatableBuffer` 的窗口 = `2 × HttpConfig.halfBufferSize`（默认 4096）。 */
private const WINDOW_BYTES: Int64 = 4096

private func bytesOf(text: String): Array<Byte> {
    text.unsafeBytes()
}

/** RFC 1867 的 `multipart/form-data`：`--b\r\n` + 首部 + `\r\n` + 内容 + `\r\n` …… + `--b--\r\n`。 */
private func multipartBytes(boundary: String, parts: Array<(String, Array<Byte>)>): Array<Byte> {
    let out = ArrayList<Byte>()
    for ((header, body) in parts) {
        out.add(all: bytesOf("--${boundary}\r\n"))
        out.add(all: bytesOf(header))
        out.add(all: bytesOf("\r\n"))
        out.add(all: body)
        out.add(all: bytesOf("\r\n"))
    }
    out.add(all: bytesOf("--${boundary}--\r\n"))
    out.unsafeData()
}

/** 首部以 `\r\n` 结尾（不含空行），`multipartBytes` 会补空行。 */
private func formPart(name: String, value: String): (String, Array<Byte>) {
    ('Content-Disposition: form-data; name="${name}"\r\n', bytesOf(value))
}

private func filePart(name: String, filename: String, contentType: String, body: Array<Byte>): (String, Array<Byte>) {
    ('Content-Disposition: form-data; name="${name}"; filename="${filename}"\r\nContent-Type: ${contentType}\r\n',
        body)
}

private func fillBytes(count: Int64, value: Byte): Array<Byte> {
    Array<Byte>(count, repeat: value)
}

private func ascendingBytes(count: Int64): Array<Byte> {
    let bytes = Array<Byte>(count, repeat: 0)
    for (i in 0..count) {
        bytes[i] = UInt8(i % 256)
    }
    bytes
}

private func parseForm(payload: Array<Byte>): Data {
    MultipartFormDataParser(ByteBuffer(payload), formDataMediaType(), TEST_BOUNDARY).parse()
}

private func parseMixed(payload: Array<Byte>): Data {
    MultipartFormDataParser(ByteBuffer(payload), mixedMediaType(), TEST_BOUNDARY).parse()
}

private func tuplesOf(data: Data): DataMultipartTuples {
    if (let p: DataMultipartTuples <- data) {
        return p
    }
    throw MultipartException('parse() 返回的不是 DataMultipartTuples')
}

private func listOf(data: Data): DataMultipartList {
    if (let p: DataMultipartList <- data) {
        return p
    }
    throw MultipartException('parse() 返回的不是 DataMultipartList')
}

private func valueOf(data: Data, name: String): String {
    tuplesOf(data).get(name).toString()
}

private func fileOf(data: Data, name: String): MultipartFile {
    if (let f: MultipartFile <- tuplesOf(data).get(name)) {
        return f
    }
    throw MultipartException('${name} 不是文件 part')
}

/**
 * 落盘 part 的字节：自己按块读，读完只调一次 `close()`（文件与空目录由它删除）。
 * 这样能单独覆盖 `MultipartFile.read()`；`bytes()` 路径由 `testSpilledFileBytes` 覆盖。
 */
private func readSpilled(part: MultipartFile): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(256, repeat: 0)
    while (true) {
        let len = part.read(buffer)
        if (len <= 0) {
            break
        }
        out.add(all: buffer[0 .. len])
    }
    part.close()
    out.unsafeData()
}

private func expectBytes(expected: Array<Byte>, actual: Array<Byte>): Unit {
    @Assert(expected.size, actual.size)
    for (i in 0..min(expected.size, actual.size)) {
        @Assert(expected[i], actual[i])
    }
}

@Test
class MultipartFormDataParser_test {
    @TestCase
    public func testSingleFormField(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("title", "Hello")])
        @Assert("Hello", valueOf(parseForm(payload), "title"))
    }

    // 空内容 part 的回归见 MultipartEmptyPart_test。

    @TestCase
    public func testMultipleFormFields(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [
            formPart("first", "1"),
            formPart("second", "2"),
            formPart("third", "3")
        ])
        let parts = parseForm(payload)
        @Assert("1", valueOf(parts, "first"))
        @Assert("2", valueOf(parts, "second"))
        @Assert("3", valueOf(parts, "third"))
    }

    @TestCase
    public func testDuplicateFieldNames(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [
            formPart("dup", "a"),
            formPart("dup", "b")
        ])
        match (tuplesOf(parseForm(payload)).get("dup")) {
            case it: DataIterable =>
                let values = ArrayList<String>()
                for (item in it) {
                    values.add(item.toString())
                }
                @Assert(2, values.size)
                @Assert("a", values[0])
                @Assert("b", values[1])
            case _ => @Fail('重名字段应返回 DataIterable')
        }
    }

    @TestCase
    public func testUtf8FieldValue(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("greeting", "中文🙂")])
        @Assert("中文🙂", valueOf(parseForm(payload), "greeting"))
    }

    @TestCase
    public func testFieldWithContentType(): Unit {
        let header = 'Content-Disposition: form-data; name="note"\r\nContent-Type: text/plain; charset=UTF-8\r\n'
        let payload = multipartBytes(TEST_BOUNDARY, [(header, bytesOf("Hello"))])
        @Assert("Hello", valueOf(parseForm(payload), "note"))
    }

    @TestCase
    public func testFieldWithoutContentTypeLine(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("only", "no-type")])
        @Assert("no-type", valueOf(parseForm(payload), "only"))
    }

    @TestCase
    public func testSmallFilePartInMemory(): Unit {
        let body = ascendingBytes(32)
        let payload = multipartBytes(TEST_BOUNDARY, [
            formPart("tag", "x"),
            filePart("upload", "small.bin", "application/octet-stream", body)
        ])
        let file = fileOf(parseForm(payload), "upload")
        @Assert("small.bin", file.filename)
        @Assert(32, file.size)
        expectBytes(body, readSpilled(file))
    }

    @TestCase
    public func testLargeFilePartSpilledToDisk(): Unit {
        let body = ascendingBytes(WINDOW_BYTES * 2)
        let payload = multipartBytes(TEST_BOUNDARY, [
            filePart("upload", "large.bin", "application/octet-stream", body)
        ])
        let file = fileOf(parseForm(payload), "upload")
        @Assert("large.bin", file.filename)
        @Assert(body.size, file.size)
        expectBytes(body, readSpilled(file))
    }

    @TestCase
    public func testMixedFormAndFiles(): Unit {
        let small = ascendingBytes(16)
        let big = ascendingBytes(WINDOW_BYTES + 1000)
        let payload = multipartBytes(TEST_BOUNDARY, [
            formPart("a", "alpha"),
            filePart("f1", "one.bin", "application/octet-stream", small),
            formPart("b", "beta"),
            filePart("f2", "two.bin", "application/octet-stream", big)
        ])
        let parts = parseForm(payload)
        @Assert("alpha", valueOf(parts, "a"))
        @Assert("beta", valueOf(parts, "b"))
        expectBytes(small, readSpilled(fileOf(parts, "f1")))
        expectBytes(big, readSpilled(fileOf(parts, "f2")))
    }

    @TestCase
    public func testContentContainsCrlf(): Unit {
        let value = "line1\r\n\r\nline2"
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("text", value)])
        @Assert(value, valueOf(parseForm(payload), "text"))
    }

    @TestCase
    public func testContentContainsBoundaryPrefix(): Unit {
        let value = "before--${TEST_BOUNDARY}after"
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("text", value)])
        @Assert(value, valueOf(parseForm(payload), "text"))
    }

    @TestCase
    public func testContentEndsWithCr(): Unit {
        let value = "tail\r"
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("text", value)])
        @Assert(value, valueOf(parseForm(payload), "text"))
    }

    @TestCase
    public func testLargeTextFieldStreamed(): Unit {
        let value = String.fromUtf8(fillBytes(WINDOW_BYTES * 2, 0x61))
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("text", value)])
        @Assert(value.size, valueOf(parseForm(payload), "text").size)
    }

    @TestCase
    public func testBinaryPayloadBytes(): Unit {
        let body: Array<Byte> = [0x00, 0x01, 0xFF, 0xFE, 0x00, 0x80, 0x0A, 0x0D]
        let payload = multipartBytes(TEST_BOUNDARY, [
            filePart("upload", "bin.dat", "application/octet-stream", body)
        ])
        expectBytes(body, fileOf(parseForm(payload), "upload").bytes())
    }

    @TestCase
    public func testSpilledFileBytes(): Unit {
        let body = fillBytes(WINDOW_BYTES * 2, 0x5A)
        let payload = multipartBytes(TEST_BOUNDARY, [
            filePart("big", "big.bin", "application/octet-stream", body)
        ])
        expectBytes(body, fileOf(parseForm(payload), "big").bytes())
    }

    @TestCase
    public func testMissingLeadingBoundary(): Unit {
        let payload = bytesOf('Content-Disposition: form-data; name="a"\r\n\r\nvalue\r\n')
        @ExpectThrows[MultipartException](parseForm(payload))
    }

    @TestCase
    public func testMissingClosingBoundary(): Unit {
        let payload = bytesOf('--${TEST_BOUNDARY}\r\nContent-Disposition: form-data; name="a"\r\n\r\nvalue\r\n')
        @ExpectThrows[MultipartException](parseForm(payload))
    }

    @TestCase
    public func testHeaderWithoutDoubleCrlf(): Unit {
        let payload = bytesOf('--${TEST_BOUNDARY}\r\nContent-Disposition: form-data; name="a"\r\n')
        // 现状：headerLen = -1 - start + 4 < 0，由 `Array<Byte>(负数)` 抛出。
        @ExpectThrows[NegativeArraySizeException](parseForm(payload))
    }

    @TestCase
    public func testUnsupportedMediaType(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [formPart("a", "1")])
        @ExpectThrows[MultipartException](
            MultipartFormDataParser(ByteBuffer(payload), "text/plain", TEST_BOUNDARY).parse())
    }

    @TestCase
    public func testMixedMediaTypeProducesList(): Unit {
        let first = ascendingBytes(8)
        let second = ascendingBytes(12)
        let payload = multipartBytes(TEST_BOUNDARY, [
            ('Content-Disposition: attachment; filename="one.bin"\r\n', first),
            ('Content-Disposition: attachment; filename="two.bin"\r\n', second)
        ])
        let parts = listOf(parseMixed(payload))
        if (let f1: MultipartFile <- parts.get(0).getOrThrow()) {
            @Assert("one.bin", f1.filename)
            expectBytes(first, f1.bytes())
        } else {
            @Fail('第一个 part 不是 MultipartFile')
        }
        if (let f2: MultipartFile <- parts.get(1).getOrThrow()) {
            @Assert("two.bin", f2.filename)
            expectBytes(second, f2.bytes())
        } else {
            @Fail('第二个 part 不是 MultipartFile')
        }
    }

    @TestCase
    public func testRepeatedParseOnFreshParserIsDeterministic(): Unit {
        let payload = multipartBytes(TEST_BOUNDARY, [
            formPart("a", "alpha"),
            formPart("b", "beta")
        ])
        let first = parseForm(payload)
        let second = parseForm(payload)
        @Assert(valueOf(first, "a"), valueOf(second, "a"))
        @Assert(valueOf(first, "b"), valueOf(second, "b"))
    }
}
