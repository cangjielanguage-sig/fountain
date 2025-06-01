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

public class FileDownload {
    private static let random = RandomString()
    private let responseBuilder: HttpResponseBuilder
    private let writer: HttpResponseWriter
    private let built = AtomicBool(false)
    private let boundary = "----${random.randomLettersNumbers(32)}"
    public FileDownload(
        private let ctx: HttpContext,
        private let multi!: Bool = false,
        private let contentType!: String = "application/octet-stream") {
        responseBuilder = ctx.responseBuilder
        writer = HttpResponseWriter(ctx)
    }
    public func noContent(): Unit {
        let status = HttpStatus.NO_CONTENT
        responseBuilder.status(status.value).body(status.reasonPhrase).build()
    }
    public func write(file: File): Unit {
        let info = file.info
        if (info.isRegular()) {
            write(info.path.fileName, file, length: info.size)
        } else {
            throw HttpResponseException("${info.path} is not a file")
        }
    }
    public func write(filename: String, input: InputStream, length!: Int64 = -1) {
        if (!built.load()) {
            if (multi) {
                responseBuilder.header("Content-Type", "multipart/x-mixed-replace; boundary=${boundary}")
                responseBuilder.build()
                write("--${boundary}\r\n")
            } else {
                responseBuilder.header("Content-Disposition", attachment(filename))
                responseBuilder.header("Content-Type", contentType)
                if(length >= 0) {
                    responseBuilder.header("Content-Length", length.toString())
                }
                responseBuilder.build()
            }
            built.store(true)
        }
        func write() {
            let buf = Array<Byte>(MVCConfig.downloadBufferSize, repeat: 0)
            while(let len <- input.read(buf)) {
                if(len > 0) {
                    writer.write(buf[0 .. len])
                } else {
                    break
                }
            }
        }

        if (multi) {
            write("Content-Disposition: ${attachment(filename)}\r\n")
            if(length >= 0) {
                write("Content-Length: ${length}\r\n")
            }
            write("Content-Type: ${contentType}\r\n\r\n")
            write()
            write("\r\n--${boundary}\r\n")
        } else {
            write()
            end()
        }
    }
    public func end() {
        if (multi) {
            write("--${boundary}--")
        }
    }
    private func attachment(filename: String) {
        "attachment, filename=\"${filename}\""
    }
    private func write(header: String) {
        writer.write(header.unsafeBytes())
    }
}
