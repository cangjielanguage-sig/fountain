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
package fountain::f_email.model

import std.fs.{File, FileInfo, OpenMode, Path, removeIfExists}
import std.io.InputStream

/**
 * 正文来源。
 *
 * `open()` 每次返回一个新的读流；一次性来源（[StreamBodySource]）第二次调用必须失败——
 * 静默返回空流比抛异常更糟：调用方会以为邮件正文是空的。
 */
public interface BodySource <: Resource {
    func open(): InputStream

    /** -1 表示未知。 */
    prop size: Int64

    prop reusable: Bool
}

/** 内存中的正文（图片、小附件、SMTP `precomputeSize` 的中间结果）。 */
public class MemoryBodySource <: BodySource {
    private let bytes: Array<Byte>
    private var closed = false

    public init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func open(): InputStream {
        if (closed) {
            throw MimeException("BodySource 已关闭")
        }
        ArrayInput(bytes)
    }

    public prop size: Int64 {
        get() {
            bytes.size
        }
    }

    public prop reusable: Bool {
        get() {
            true
        }
    }

    public func close(): Unit {
        closed = true
    }

    public func isClosed(): Bool {
        closed
    }
}

/**
 * 文件正文。
 *
 * `owned=true` 时 [close] 会删除文件（解析器把大附件落盘到临时文件时使用）；
 * 调用方传入自己的附件文件时必须保持 `owned=false`，否则会把用户的源文件删掉。
 */
public class FileBodySource <: BodySource {
    private let path: Path
    private let owned: Bool
    private var closed = false

    public init(path: Path, owned!: Bool = false) {
        this.path = path
        this.owned = owned
    }

    public func open(): InputStream {
        if (closed) {
            throw MimeException("BodySource 已关闭：${path}")
        }
        File(path, OpenMode.Read)
    }

    public prop size: Int64 {
        get() {
            try {
                FileInfo(path).size
            } catch (_: Exception) {
                -1
            }
        }
    }

    public prop reusable: Bool {
        get() {
            true
        }
    }

    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        if (owned) {
            try {
                removeIfExists(path)
            } catch (_: Exception) {}
        }
    }

    public func isClosed(): Bool {
        closed
    }
}

/** 一次性流来源（POP3 `RETR` / IMAP literal 直接接解析器时使用）。 */
public class StreamBodySource <: BodySource {
    private var input: ?InputStream
    private let knownSize: Int64
    private var closed = false

    public init(input: InputStream, size!: Int64 = -1) {
        this.input = Some(input)
        this.knownSize = size
    }

    public func open(): InputStream {
        if (closed) {
            throw MimeException("BodySource 已关闭")
        }
        match (input) {
            case Some(stream) =>
                input = None
                stream
            case None => throw MimeException("一次性 BodySource 只能打开一次，请先落盘为 FileBodySource")
        }
    }

    public prop size: Int64 {
        get() {
            knownSize
        }
    }

    public prop reusable: Bool {
        get() {
            false
        }
    }

    public func close(): Unit {
        // 底层流的生命周期归构造方所有：这里只把引用丢掉，避免重复关闭别人的 socket。
        closed = true
        input = None
    }

    public func isClosed(): Bool {
        closed
    }
}
