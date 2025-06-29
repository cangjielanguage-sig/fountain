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

/**
https://www.rfc-editor.org/rfc/rfc1867
multipart/form-data
        Content-type: multipart/form-data, boundary=AaB03x

        --AaB03x
        content-disposition: form-data; name="field1"

        Joe Blow
        --AaB03x
        content-disposition: form-data; name="pics"; filename="file1.txt"
        Content-Type: text/plain

         ... contents of file1.txt ...
        --AaB03x--



multipart/form-data multipart/mixed
        Content-type: multipart/form-data, boundary=AaB03x

        --AaB03x
        content-disposition: form-data; name="field1"

        Joe Blow
        --AaB03x
        content-disposition: form-data; name="pics"
        Content-type: multipart/mixed, boundary=BbC04y

        --BbC04y
        Content-disposition: attachment; filename="file1.txt"
        Content-Type: text/plain

        ... contents of file1.txt ...
        --BbC04y
        Content-disposition: attachment; filename="file2.gif"
        Content-type: image/gif
        Content-Transfer-Encoding: binary

          ...contents of file2.gif...
        --BbC04y--
        --AaB03x--
 */
class MultipartFormDataParser {
    private static let uploadDir = MVCConfig.uploadDir
    private static let uploadStoreInMemory = MVCConfig.uploadStoreInMemory
    private let boundary: String
    private let bodyStream: InputStream
    private let bodyDelimiter: Array<Byte>
    private let bodyStart: Array<Byte>
    private let bodyEnd: Array<Byte>
    private let bodyIndexer: BodyIndexer
    private let path: String
    private let indexer: BodyIndexer
    MultipartFormDataParser(private let ctx: HttpContext) {
        let contentType = ctx.request.headers.getFirst("Content-Type") ?? ""
        if (contentType == "") {
            throw HttpRequestHeaderException("No Content-Type of http request header")
        } else if (!contentType.startsWith("multipart/form-data; boundary=")) {
            throw HttpRequestHeaderException(
                "Content-Type of http request header does not match, ${contentType}, Content-Type must start with multipart/form-data; boundary="
            )
        }
        boundary = extractBoundary(contentType)
        bodyStream = ctx.request.body
        bodyStart = genBodyStart(boundary)
        bodyDelimiter = genBodyDelimiter(boundary)
        bodyEnd = genBodyEnd(boundary)
        bodyIndexer = BodyIndexer(bodyStream, bodyStart, bodyDelimiter, bodyEnd)
        path = if (!uploadStoreInMemory) {
            let part = "${DateTime.now()}${boundary}"
            let path = if (uploadDir.endsWith("/")) {
                "${uploadDir}${part}"
            } else {
                "${uploadDir}/${part}"
            }
            Directory.createTemp(path)
            path
        } else {
            ""
        }
        indexer = BodyIndexer(bodyStream, bodyStart, bodyDelimiter, bodyEnd)
        if (!indexer.checkStart()) {
            throw MultipartFormDataException(
                "current request body does not match multipart/form-data, it does not starts with the boundary")
        }
    }
    private static func genBodyStart(boundary: String) {
        "\r\n--${boundary}\r\n".unsafeBytes()
    }
    private static func genBodyDelimiter(boundary: String) {
        "\r\n--${boundary}\r\n".unsafeBytes()
    }
    private static func genBodyEnd(boundary: String) {
        "\r\n--${boundary}--".unsafeBytes()
    }
    private static let CONTENT_TYPE_BYTES = "Content-Type".unsafeBytes()

    static func extractBoundary(contentType: String) {
        contentType["multipart/form-data; boundary=".size..]
    }
    func parse(): Multiparts {
        let parts = Multiparts()
        while (indexer.notEnd()) {
            var header = extractHeaderFromBody(indexer)
            let contentDisposition = ContentDisposition.parse(header[1])
            if (contentDisposition.getFilename().isEmpty()) {
                func partPadding() {
                    var partEnd = -1
                    let list = ArrayList<Byte>()
                    do {
                        partEnd = indexer.indexOf(bodyDelimiter)
                        indexer.slice(false, list)
                    } while (partEnd < 0)
                    list
                }
                if (indexer.sliceFrom == indexer.indexOf(CONTENT_TYPE_BYTES)) {
                    header = extractHeaderFromBody(indexer)
                    let headerValue = header[1]
                    if (headerValue.startsWith("multipart/mixed")) {
                        let boundary = headerValue[headerValue
                                .indexOf(", boundary=")
                                .getOrThrow {MultipartFormDataException("${headerValue} is without boundary")} + ", boundary="
                                .size..]
                        let bodyStart = indexer.bodyStart
                        let bodyDelimiter = indexer.bodyDelimiter
                        let bodyEnd = indexer.bodyEnd
                        indexer.bodyStart = genBodyStart(boundary)
                        indexer.bodyDelimiter = genBodyDelimiter(boundary)
                        indexer.bodyEnd = genBodyEnd(boundary)
                        parts.add(
                            match (parse()) {
                                case x: Multiparts => MultipartMixed(contentDisposition, x)
                                case x: Multiparts => MultipartMixed(contentDisposition, x)
                                case _ => throw MultipartFormDataException("unreachable")
                            })
                        indexer.bodyStart = bodyStart
                        indexer.bodyDelimiter = bodyDelimiter
                        indexer.bodyEnd = bodyEnd
                        indexer.sliceFrom -= 2
                        indexer.indexOf(bodyDelimiter, rotate: true)
                        continue
                    } else if (headerValue == "application/x-www-form-urlencoded") {
                        indexer.indexOf(lineDelim, rotate: true) //此处必须有一行这个，必须跟【OTHER】处的相同代码同时存在
                        let list = partPadding()
                        if (!list.isEmpty()) {
                            parts.setForm(contentDisposition.getName(), Form((String.fromUtf8(list.unsafeData()))))
                        }
                        continue
                    } else {
                        indexer.indexOf(lineDelim, rotate: true) //此处必须有一行这个，必须跟【OTHER】处的相同代码同时存在
                        let list = partPadding()
                        let mediaType = if(headerValue.isEmpty()){
                            None<MediaType>
                        }else{
                            MediaTypes.parse(headerValue)
                        }
                        let part = MultipartMedia(contentDisposition, mediaType, list.unsafeData())
                        parts.add(part)
                        continue
                    }
                }
                indexer.indexOf(lineDelim, rotate: true) //【OTHER】
                var partEnd = -1
                let list = partPadding()
                let value = if (list.isEmpty()) {
                    ""
                } else {
                    URL.parse(String.fromUtf8(list.unsafeData())).path
                }
                ctx.request.form.add(contentDisposition.getName(), value)
            } else {
                let filename = contentDisposition.getFilename()
                ctx.request.form.add(contentDisposition.getName(), filename)
                let header = extractHeaderFromBody(indexer)
                let (stream, file): (OutputStream, Multipart) = if (uploadStoreInMemory) {
                    let stream = ByteBuffer()
                    let file = MultipartFile(contentDisposition, stream)
                    (stream, file)
                } else {
                    let filepath = "${path}/${filename}"
                    let stream = File(filepath, Read)
                    let file = MultipartFile(contentDisposition, stream)
                    (File(filepath, Write), file)
                }
                try {
                    var partEnd = -1
                    do {
                        partEnd = indexer.indexOf(bodyDelimiter)
                        indexer.output(false, stream)
                    } while (partEnd < 0)
                    parts.add(file)
                } finally {
                    match (stream) {
                        case x: Resource => x.close()
                        case _ => ()
                    }
                }
            }
        }
        parts
    }
    private static let headerDelim = ":".unsafeBytes()
    private static let lineDelim = "\r\n".unsafeBytes()
    private func extractHeaderFromBody(indexer: BodyIndexer) {
        let headerName = findSlice(indexer, headerDelim)
        let headerValue = findSlice(indexer, lineDelim)
        if(headerName.isEmpty()) {
            ('', '')
        }else{
            (headerName, headerValue)
        }
    }
    private func findSlice(indexer: BodyIndexer, delim: Array<Byte>): String {
        let found = indexer.indexOf(delim)
        if (found > 0) {
            let slice = indexer.slice(delim == lineDelim)
            String.fromUtf8(slice).trimAscii()
        } else {
            ''
        }
    }
}

class BodyIndexer {
    private static let uploadHalfBufferSize = MVCConfig.uploadHalfBufferSize
    BodyIndexer(
        private let body: InputStream,
        var bodyStart: Array<Byte>,
        var bodyDelimiter: Array<Byte>,
        var bodyEnd: Array<Byte>
    ) {
        rotateIfNecessary(false)
    }

    private var first = EmptyArray<Byte>.INSTANCE()
    private var second = EmptyArray<Byte>.INSTANCE()
    private var firstLength = 0
    private var secondLength = 0
    var foundOffset = -1
    var sliceFrom = 0

    public prop size: Int64 {
        get() {
            firstLength + secondLength
        }
    }
    public func at(index: Int64): Option<Byte> {
        if (index < firstLength) {
            first[index]
        } else if (index - firstLength < secondLength) {
            second[index - firstLength]
        } else {
            None
        }
    }
    func output(lineSlice: Bool, stream: OutputStream): Unit {
        func innerOutput(secondLen: Int64) {
            stream.write(first[sliceFrom..firstLength])
            stream.write(second[0..secondLen])
        }
        if (foundOffset < 0) {
            innerOutput(secondLength)
        } else if (foundOffset <= firstLength) {
            stream.write(first[sliceFrom..foundOffset])
        } else if (foundOffset > firstLength) {
            innerOutput(foundOffset - firstLength)
        }
        rotateIfNecessary(lineSlice)
    }
    func slice(lineSlice: Bool): Array<Byte> {
        func innerSlice(secondLen: Int64) {
            let list = ArrayList<Byte>()
            list.add(all: first[sliceFrom..firstLength])
            list.add(all: second[0..secondLen])
            list.unsafeData()
        }
        var slc: Array<Byte> = []
        if (foundOffset < 0) {
            slc = innerSlice(secondLength)
        } else if (foundOffset <= firstLength) {
            slc = first[sliceFrom..foundOffset]
        } else if (foundOffset > firstLength) {
            slc = innerSlice(foundOffset - firstLength)
        }
        rotateIfNecessary(lineSlice)
        slc
    }
    func slice(lineSlice: Bool, list: ArrayList<Byte>): Unit {
        func innerSlice(secondLen: Int64) {
            list.add(all: first[sliceFrom..firstLength])
            list.add(all: second[0..secondLen])
        }
        if (foundOffset < 0) {
            innerSlice(secondLength)
        } else if (foundOffset < firstLength) {
            list.add(all: first[sliceFrom..foundOffset])
        } else {
            innerSlice(foundOffset - firstLength)
        }
        rotateIfNecessary(lineSlice)
    }
    private func rotateIfNecessary(lineSlice: Bool): Unit {
        func innerRotate() {
            let idle = first
            first = second
            firstLength = first.size
            let (second, secondLength) = fillBuffer(idle)
            this.second = second
            this.secondLength = secondLength
        }
        let delimiterSize = if (lineSlice) {
            2
        } else {
            bodyDelimiter.size
        }
        if (foundOffset < 0) {
            let (first, firstLength) = createBuffer()
            this.first = first
            this.firstLength = firstLength
            let (second, secondLength) = createBuffer()
            this.second = second
            this.secondLength = secondLength
            sliceFrom = 0
        } else if (size - foundOffset < delimiterSize) {
            innerRotate()
            sliceFrom = foundOffset - firstLength
        } else if (foundOffset >= firstLength) {
            sliceFrom = if (secondLength == 0) {
                first = EmptyArray<Byte>.INSTANCE()
                second = EmptyArray<Byte>.INSTANCE()
                firstLength = 0
                secondLength = 0
                0
            } else {
                innerRotate()
                foundOffset - firstLength + delimiterSize
            }
            foundOffset = 0
        } else if (firstLength - foundOffset <= delimiterSize) {
            innerRotate()
            sliceFrom = secondLength - delimiterSize + firstLength - foundOffset
        } else {
            sliceFrom = foundOffset + delimiterSize
        }
    }
    private func createBuffer() {
        let buffer = Array<Byte>(uploadHalfBufferSize, repeat: 0)
        fillBuffer(buffer)
    }
    private func fillBuffer(buffer: Array<Byte>) {
        if (buffer.size > 0) {
            let len = body.read(buffer)
            (buffer, len)
        } else {
            (buffer, 0)
        }
    }
    func checkStart(): Bool {
        let start = indexOf(bodyStart.size, bodyStart, bodyStart.size, 0) == 0
        rotateIfNecessary(false)
        start
    }
    func notEnd(): Bool {
        let end = b'-'
        match ((this.at(sliceFrom), this.at(sliceFrom + 1))) {
            case (Some(x), Some(y)) => !(x == end && y == end)
            case (None, None) => false
            case _ => true
        }
    }
    func indexOf(sub: Array<Byte>, rotate!: Bool = false): Int64 {
        try {
            indexOf(this.size, sub, sub.size, sliceFrom)
        } finally {
            if (rotate) {
                rotateIfNecessary(sub.size == 2)
            }
        }
    }

    private func indexOf(valueCount: Int64, sub: Array<Byte>, subCount: Int64, fromIndex: Int64): Int64 {
        foundOffset = if (valueCount == 0 || valueCount == fromIndex) {
            -1
        } else {
            indexOf(this, valueCount, sub, subCount, fromIndex) ?? -1
        }
        return foundOffset
    }
    private func indexOf(src: BodyIndexer, srcCount: Int64, dst: Array<Byte>, dstCount: Int64, start: Int64): ?Int64 {
        let first = dst[0]
        let max = srcCount - dstCount
        var i = start
        while (i <= max) {
            while (i <= max && if (let Some(x) <- src.at(i)) {
                    x != first
                } else {
                    return None<Int64>
                }) {
                i++
            }
            if (i <= max) {
                var j = i + 1
                let end = j + dstCount - 1
                var k = 1
                while (j < end && if (let Some(x) <- src.at(j)) {
                        x == dst[k]
                    } else {
                        return None<Int64>
                    }) {
                    j++
                    k++
                }
                if (j == end) {
                    return i
                }
            }
            i++
        }
        return None<Int64>
    }
}
