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
    MultipartFile(contentDisposition: ContentDisposition,
                  public let content: T,
                  private let charset!: Charset = Charsets.UTF8) {
        super(contentDisposition)
    }
    ~init(){
        match(content){
            case x: File =>
                try {
                    x.close()
                } catch (e: Exception) {}
                try {
                    remove(x.info.path)
                } catch (e: Exception) {}
            case _ => ()
        }
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
            pipe(input: content, output: output)
        } finally {
            close()
        }
    }
    public func readToEnd(): Array<Byte> {
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
            (content as File)?.info.parentDirectory?.path
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
        (content as Resource)?.close()
    }
}
