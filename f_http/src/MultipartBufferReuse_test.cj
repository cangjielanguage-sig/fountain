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
 * `MultipartFormDataParser` 的缓冲复用不变量（只依赖可观察行为，不碰私有字段）。
 *
 * 一个 parser 在同一次 `parse()` 内跨 part 复用三块缓冲；这里用「长 header 紧跟短 header」、
 * 「流式块被多个落盘 part 连续使用」等形状，检查残余字节不会跨 part 泄漏。
 */

private const REUSE_BOUNDARY: String = "----fountainReuseBoundary"

/** `RotatableBuffer` 的窗口 = `2 × HttpConfig.halfBufferSize`（默认 4096）。 */
private const REUSE_WINDOW: Int64 = 4096

private func reuseBytesOf(text: String): Array<Byte> {
    text.unsafeBytes()
}

private func reuseMediaType(): String {
    "multipart/form-data; boundary=${REUSE_BOUNDARY}"
}

private func reusePayload(parts: Array<(String, Array<Byte>)>): Array<Byte> {
    let out = ArrayList<Byte>()
    for ((header, body) in parts) {
        out.add(all: reuseBytesOf("--${REUSE_BOUNDARY}\r\n"))
        out.add(all: reuseBytesOf(header))
        out.add(all: reuseBytesOf("\r\n"))
        out.add(all: body)
        out.add(all: reuseBytesOf("\r\n"))
    }
    out.add(all: reuseBytesOf("--${REUSE_BOUNDARY}--\r\n"))
    out.unsafeData()
}

private func reuseFormPart(name: String, value: String): (String, Array<Byte>) {
    ('Content-Disposition: form-data; name="${name}"\r\n', reuseBytesOf(value))
}

private func reuseParse(payload: Array<Byte>): Data {
    MultipartFormDataParser(ByteBuffer(payload), reuseMediaType(), REUSE_BOUNDARY).parse()
}

private func reuseTuples(data: Data): DataMultipartTuples {
    if (let p: DataMultipartTuples <- data) {
        return p
    }
    throw MultipartException('parse() 返回的不是 DataMultipartTuples')
}

private func reuseFile(data: Data, name: String): MultipartFile {
    if (let f: MultipartFile <- reuseTuples(data).get(name)) {
        return f
    }
    throw MultipartException('${name} 不是文件 part')
}

private func reuseValue(data: Data, name: String): String {
    reuseTuples(data).get(name).toString()
}

/** 落盘 part 的字节：自己按块读，单独覆盖 `MultipartFile.read()`。 */
private func reuseSpilledBytes(part: MultipartFile): Array<Byte> {
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

private func reuseAscending(count: Int64, seed: Byte): Array<Byte> {
    let bytes = Array<Byte>(count, repeat: 0)
    for (i in 0..count) {
        bytes[i] = UInt8((Int64(seed) + i) % 256)
    }
    bytes
}

@Test
class MultipartBufferReuse_test {
    /** 2000 B header 的 part 之后紧跟 80 B header 的 part：第二个 part 的首部字段精确。 */
    @TestCase
    public func testSecondPartReusesHeaderBuffer(): Unit {
        let longFilename = String.fromUtf8(Array<Byte>(1900, repeat: 0x61))
        let smallBody = reuseAscending(8, 0x30)
        let payload = reusePayload([
            ('Content-Disposition: form-data; name="long"; filename="${longFilename}"\r\n', smallBody),
            ('Content-Disposition: form-data; name="brief"; filename="b.bin"\r\n', smallBody)
        ])
        let parts = reuseParse(payload)
        @Assert(longFilename, reuseFile(parts, "long").filename)
        @Assert("b.bin", reuseFile(parts, "brief").filename)
        @Assert(true, reuseTuples(parts).get("brief").toString().size > 0)
    }

    /** header 依次 60 / 200 / 600 / 2000 / 60 B：每轮结果精确，增长后短 header 不被污染。 */
    @TestCase
    public func testHeaderSizesGrowAndReuse(): Unit {
        let targets = [60, 200, 600, 2000, 60]
        let empty: (String, Array<Byte>) = ("", Array<Byte>(0, repeat: 0))
        let parts = Array<(String, Array<Byte>)>(targets.size, repeat: empty)
        let expected = Array<String>(targets.size, repeat: "")
        for (i in 0..targets.size) {
            let name = "p${i}"
            let prefix = 'Content-Disposition: form-data; name="${name}"; filename="'
            let pad = max(0, targets[i] - prefix.size - 2)
            let filename = String.fromUtf8(Array<Byte>(pad, repeat: UInt8(0x62 + i)))
            parts[i] = ('Content-Disposition: form-data; name="${name}"; filename="${filename}"\r\n',
                reuseAscending(4, UInt8(0x40 + i)))
            expected[i] = filename
        }
        let parsed = reuseParse(reusePayload(parts))
        for (i in 0..expected.size) {
            let file = reuseFile(parsed, "p${i}")
            @Assert(expected[i].size, file.filename.size)
            @Assert(expected[i], file.filename)
        }
    }

    /** 3 个落盘文件 part 连续使用同一块 1024 B 流式缓冲：内容逐字节精确。 */
    @TestCase
    public func testStreamChunkSharedAcrossFileParts(): Unit {
        let bodies = [
            reuseAscending(REUSE_WINDOW + 100, 0x11),
            reuseAscending(REUSE_WINDOW + 200, 0x22),
            reuseAscending(REUSE_WINDOW + 300, 0x33)
        ]
        let payload = reusePayload([
            ('Content-Disposition: form-data; name="f0"; filename="f0.bin"\r\n', bodies[0]),
            ('Content-Disposition: form-data; name="f1"; filename="f1.bin"\r\n', bodies[1]),
            ('Content-Disposition: form-data; name="f2"; filename="f2.bin"\r\n', bodies[2])
        ])
        let parts = reuseParse(payload)
        for (i in 0..3) {
            let actual = reuseSpilledBytes(reuseFile(parts, "f${i}"))
            @Assert(bodies[i].size, actual.size)
            for (j in 0..bodies[i].size) {
                @Assert(bodies[i][j], actual[j])
            }
        }
    }

    /** 超窗口的长字段值（流式分支）之后紧跟短字段值：短值长度精确，无残留。 */
    @TestCase
    public func testStaleTailDoesNotLeakIntoFieldValue(): Unit {
        let long = String.fromUtf8(Array<Byte>(REUSE_WINDOW + 700, repeat: 0x61))
        let payload = reusePayload([
            reuseFormPart("long", long),
            reuseFormPart("tiny", "z")
        ])
        let parts = reuseParse(payload)
        @Assert(long.size, reuseValue(parts, "long").size)
        @Assert(1, reuseValue(parts, "tiny").size)
        @Assert("z", reuseValue(parts, "tiny"))
    }

    /** 两个 parser 交替解析不同报文：各自的缓冲互不影响。 */
    @TestCase
    public func testSequentialParsersIndependent(): Unit {
        let payloadA = reusePayload([
            reuseFormPart("a1", "one"),
            reuseFormPart("a2", "two")
        ])
        let payloadB = reusePayload([
            ('Content-Disposition: form-data; name="b1"; filename="b.bin"\r\n', reuseAscending(24, 0x55))
        ])
        let first = reuseParse(payloadA)
        let second = reuseParse(payloadB)
        let third = reuseParse(payloadA)
        @Assert("one", reuseValue(first, "a1"))
        @Assert("b.bin", reuseFile(second, "b1").filename)
        @Assert("two", reuseValue(third, "a2"))
        @Assert(24, reuseFile(second, "b1").size)
    }
}
