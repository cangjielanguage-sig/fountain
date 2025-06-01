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
 * multipart/form-data, boundary=AaB03x
 */
public class MultipartMediaType <: MediaType {
    private static const MEDIA_TYPE_NAME = "multipart/form-data"
    public static let instance = MultipartMediaType(MEDIA_TYPE_NAME)
    private MultipartMediaType(
        mediaType: String,
        public let boundary!: String = ""
    ) {
        super(mediaType)
    }
    public func toString() {
        "${mediaType}; boundary=${boundary}"
    }
    public operator func ==(other: MediaType) {
        match (other) {
            case x: MultipartMediaType => x.mediaType == this.mediaType && x.boundary == this.boundary
            case _ => false
        }
    }
    public func hashCode(): Int64 {
        if (hash == 0) {
            hash = HashBuilder().append(mediaType).append(boundary).finish()
        }
        hash
    }
    public func make(mediaType: String): MediaType {
        if (mediaType.startsWith(MEDIA_TYPE_NAME)) {
            let idx = mediaType.indexOf(", boundary=") ?? -1
            if (idx > 0) {
                MultipartMediaType(mediaType[0..idx], boundary: mediaType[idx + ", boundary=".size..])
            } else if (mediaType == MEDIA_TYPE_NAME) {
                this
            } else {
                throw MediaTypeException("${mediaType} is illegal")
            }
        } else {
            throw MediaTypeException("${mediaType} is not multipart/form-data")
        }
    }

    public func fromData(data: Data): Array<Byte> {
        throw MediaTypeException("${MEDIA_TYPE_NAME} does not support current access")
    }
    public func toData(data: Array<Byte>): Data {
        throw MediaTypeException("${MEDIA_TYPE_NAME} does not support current access")
    }
    private static let multipart = ThreadLocal<Any>()
    public func parse(ctx: HttpContext): Multiparts {
        match (multipart.get()) {
            case Some(x) => (x as Multiparts).getOrThrow()
            case _ =>
                let parts = MultipartFormDataParser(ctx).parse()
                multipart.set(parts)
                parts
        }
    }
    func clear() {
        multipart.remove()
    }
}