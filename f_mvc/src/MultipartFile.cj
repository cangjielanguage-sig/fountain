/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

public class MultipartFile<T> <: Multipart & InputStream & Resource where T <: InputStream {
    MultipartFile(
        contentDisposition: ContentDisposition,
        public let content: T,
        private let charset!: Charset = Charsets.UTF8
    ) {
        super(contentDisposition)
    }
    ~init() {
        doClose(content, toThrow: false)
    }
    public prop empty: Bool {
        get() {
            size == 0
        }
    }
    func setType(`type`: String): Unit {
        contentDisposition.setType(ContentDispositionType.tryParse(`type`).getOrThrow())
    }
    public prop isAttachment: Bool {
        get() {
            contentDisposition.isAttachment
        }
    }
    public prop isInline: Bool {
        get() {
            contentDisposition.isInline
        }
    }
    public prop isFormData: Bool {
        get() {
            contentDisposition.isFormData
        }
    }
    public func getType(): ContentDispositionType {
        contentDisposition.getType()
    }
    func setFilename(filename: String): Unit {
        contentDisposition.setFilename(filename)
    }
    public prop filename: String {
        get() {
            contentDisposition.getFilename()
        }
    }
    func setSize(size: Int64): Unit {
        contentDisposition.setSize(size)
    }
    public prop size: Int64 {
        get() {
            contentDisposition.getSize()
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        content.read(buffer)
    }
    public func copyTo(output: OutputStream): Unit {
        try {
            match (content) {
                case input: ByteBuffer => copy(input, to: output)
                case file: File => copy(file, to: output)
                case _ =>
                    let buffer = Array<Byte>(4096, repeat: 0)
                    while (true) {
                        let len = content.read(buffer)
                        if (len > 0) {
                            output.write(buffer.slice(0, len))
                        } else {
                            return
                        }
                    }
            }
        } finally {
            close()
        }
    }
    public func bytes(): Array<Byte> {
        try {
            match (content) {
                case input: ByteBuffer => input.bytes()
                case _ =>
                    let buffer = ByteBuffer()
                    copyTo(buffer)
                    buffer.bytes()
            }
        } finally {
            close()
        }
    }
    prop directory: ?Path {
        get() {
            match (content) {
                case file: File => (file.info.parentDirectory?.path) ?? Path('/')
                case _ => None
            }
        }
    }
    public prop reader: TextReader {
        get() {
            TextReader(content, charset: charset)
        }
    }
    public func isClosed(): Bool {
        (content as Resource)?.isClosed() ?? false
    }
    public func close(): Unit {
        doClose(content)
    }
    private static func doClose(input: InputStream, toThrow!: Bool = true) {
        match (input) {
            case x: File =>
                try {
                    x.close()
                } catch (e: Exception) {
                    if (toThrow) {
                        throw e
                    }
                }
                try {
                    removeIfExists(x.info.path, recursive: false)
                } catch (e: Exception) {
                    if (toThrow) {
                        throw e
                    }
                }
                try {
                    if (Directory.isEmpty(x.info.path.parent)) {
                        removeIfExists(x.info.path.parent, recursive: true)
                    }
                } catch (e: Exception) {
                    if (toThrow) {
                        throw e
                    }
                }
            case x: Resource => x.close()
            case _ => ()
        }
    }
}
