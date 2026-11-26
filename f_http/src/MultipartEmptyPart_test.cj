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
 * 空内容 part：内容长度为 0 的字段值与 0 B 文件。
 *
 * 这些形状依赖 `RotatableBuffer` 延迟跳过分隔符：header 读取恰好结束在 sectionEnd 时，
 * 分隔符必须仍然可见，parse() 才能得到 `end == offset` 的零长度分支。
 */

private const EMPTY_BOUNDARY: String = "----emptyPartBoundary"

/** `RotatableBuffer` 的窗口 = `2 × HttpConfig.halfBufferSize`（默认 4096）。 */
private const EMPTY_WINDOW: Int64 = 4096

private func emptyMediaType(): String {
    "multipart/form-data; boundary=${EMPTY_BOUNDARY}"
}

private func emptyPayload(parts: Array<(String, Array<Byte>)>): Array<Byte> {
    let out = ArrayList<Byte>()
    for ((header, body) in parts) {
        out.add(all: "--${EMPTY_BOUNDARY}\r\n".unsafeBytes())
        out.add(all: header.unsafeBytes())
        out.add(all: "\r\n".unsafeBytes())
        out.add(all: body)
        out.add(all: "\r\n".unsafeBytes())
    }
    out.add(all: "--${EMPTY_BOUNDARY}--\r\n".unsafeBytes())
    out.unsafeData()
}

private func emptyFormPart(name: String, value: String): (String, Array<Byte>) {
    ('Content-Disposition: form-data; name="${name}"\r\n', value.unsafeBytes())
}

private func emptyFilePart(name: String, filename: String, body: Array<Byte>): (String, Array<Byte>) {
    ('Content-Disposition: form-data; name="${name}"; filename="${filename}"\r\nContent-Type: application/octet-stream\r\n',
        body)
}

private func emptyParse(parts: Array<(String, Array<Byte>)>): Data {
    MultipartFormDataParser(ByteBuffer(emptyPayload(parts)), emptyMediaType(), EMPTY_BOUNDARY).parse()
}

private func emptyTuples(data: Data): DataMultipartTuples {
    if (let p: DataMultipartTuples <- data) {
        return p
    }
    throw MultipartException('parse() 返回的不是 DataMultipartTuples')
}

private func emptyValue(data: Data, name: String): String {
    emptyTuples(data).get(name).toString()
}

private func emptyFile(data: Data, name: String): MultipartFile {
    if (let f: MultipartFile <- emptyTuples(data).get(name)) {
        return f
    }
    throw MultipartException('${name} 不是文件 part')
}

private func ascending(count: Int64, seed: Byte): Array<Byte> {
    let bytes = Array<Byte>(count, repeat: 0)
    for (i in 0..count) {
        bytes[i] = UInt8((Int64(seed) + i) % 256)
    }
    bytes
}

@Test
class MultipartEmptyPart_test {
    /** 报文只有一个空字段：不抛异常，值为空。 */
    @TestCase
    public func testEmptyFieldAlone(): Unit {
        let data = emptyParse([emptyFormPart("empty", "")])
        @Assert(0, emptyValue(data, "empty").size)
    }

    /** 空字段在普通字段之前。 */
    @TestCase
    public func testEmptyFieldBeforeValue(): Unit {
        let data = emptyParse([
            emptyFormPart("empty", ""),
            emptyFormPart("second", "y")
        ])
        @Assert(0, emptyValue(data, "empty").size)
        @Assert("y", emptyValue(data, "second"))
    }

    /** 空字段在普通字段之后。 */
    @TestCase
    public func testEmptyFieldAfterValue(): Unit {
        let data = emptyParse([
            emptyFormPart("first", "x"),
            emptyFormPart("empty", "")
        ])
        @Assert("x", emptyValue(data, "first"))
        @Assert(0, emptyValue(data, "empty").size)
    }

    /** 空字段夹在两个普通字段之间。 */
    @TestCase
    public func testEmptyFieldInMiddle(): Unit {
        let data = emptyParse([
            emptyFormPart("a", "1"),
            emptyFormPart("empty", ""),
            emptyFormPart("b", "2")
        ])
        @Assert("1", emptyValue(data, "a"))
        @Assert(0, emptyValue(data, "empty").size)
        @Assert("2", emptyValue(data, "b"))
    }

    /** 连续两个空字段：互不吞并首部，值都为空。 */
    @TestCase
    public func testConsecutiveEmptyFields(): Unit {
        let data = emptyParse([
            emptyFormPart("first", ""),
            emptyFormPart("second", ""),
            emptyFormPart("tail", "z")
        ])
        @Assert(0, emptyValue(data, "first").size)
        @Assert(0, emptyValue(data, "second").size)
        @Assert("z", emptyValue(data, "tail"))
    }

    /** 超窗口字段（流式分支）之后紧跟空字段。 */
    @TestCase
    public func testEmptyFieldAfterLargeValue(): Unit {
        let large = String.fromUtf8(Array<Byte>(EMPTY_WINDOW + 900, repeat: 0x61))
        let data = emptyParse([
            emptyFormPart("large", large),
            emptyFormPart("empty", "")
        ])
        @Assert(large.size, emptyValue(data, "large").size)
        @Assert(0, emptyValue(data, "empty").size)
    }

    /** 空字段之后紧跟超窗口字段。 */
    @TestCase
    public func testEmptyFieldBeforeLargeValue(): Unit {
        let large = String.fromUtf8(Array<Byte>(EMPTY_WINDOW + 900, repeat: 0x62))
        let data = emptyParse([
            emptyFormPart("empty", ""),
            emptyFormPart("large", large)
        ])
        @Assert(0, emptyValue(data, "empty").size)
        @Assert(large.size, emptyValue(data, "large").size)
    }

    /** 0 B 文件：size 为 0，bytes() 为空数组。 */
    @TestCase
    public func testEmptyFilePart(): Unit {
        let data = emptyParse([
            emptyFormPart("tag", "t"),
            emptyFilePart("upload", "empty.bin", Array<Byte>(0, repeat: 0))
        ])
        let file = emptyFile(data, "upload")
        @Assert("empty.bin", file.filename)
        @Assert(0, file.size)
        @Assert(0, file.bytes().size)
        @Assert("t", emptyValue(data, "tag"))
    }

    /** 空字段后接两个落盘文件：分隔符未错位，文件内容逐字节正确。 */
    @TestCase
    public func testEmptyFieldFollowedByMultipleFiles(): Unit {
        let first = ascending(EMPTY_WINDOW + 100, 0x11)
        let second = ascending(EMPTY_WINDOW + 200, 0x22)
        let data = emptyParse([
            emptyFormPart("empty", ""),
            emptyFilePart("f1", "one.bin", first),
            emptyFilePart("f2", "two.bin", second)
        ])
        @Assert(0, emptyValue(data, "empty").size)
        let actualFirst = emptyFile(data, "f1").bytes()
        let actualSecond = emptyFile(data, "f2").bytes()
        @Assert(first.size, actualFirst.size)
        @Assert(second.size, actualSecond.size)
        for (i in 0..first.size) {
            @Assert(first[i], actualFirst[i])
        }
        for (i in 0..second.size) {
            @Assert(second[i], actualSecond[i])
        }
    }
}
