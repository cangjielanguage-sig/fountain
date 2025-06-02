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

public abstract class TextMediaType <: MediaType {
    protected TextMediaType(
        mediaType: String,
        public let charset!: Charset = Charsets.UTF8
    ) {
        super(mediaType)
    }
    public func toString() {
        "${mediaType}; charset=${charset}"
    }
    public operator func ==(other: MediaType) {
        match (other) {
            case x: TextMediaType => x.mediaType == this.mediaType && x.charset == this.charset
            case _ => false
        }
    }
    public func hashCode(): Int64 {
        if (hash == 0) {
            hash = HashBuilder().append(mediaType).append(charset).build()
        }
        hash
    }
}

public class JsonMediaType <: TextMediaType {
    public static let instance = JsonMediaType()
    init(charset!: Charset = Charsets.UTF8) {
        super("application/json", charset: charset)
    }
    public func make(mediaType: String): MediaType {
        let tag = "; charset="
        let idx = mediaType.indexOf(tag)
        if (let Some(x) <- idx) {
            let cs = mediaType[x + tag.size..]
            let mt = mediaType[0..x]
            if (mt == this.mediaType) {
                let charset = Charsets.forName(cs)
                if (let Some(c) <- charset) {
                    JsonMediaType(charset: c)
                } else {
                    throw MediaTypeException("charset in ${mediaType} is not be supported")
                }
            } else {
                throw MediaTypeException("${mediaType} is not ${this.mediaType}")
            }
        } else if (mediaType.startsWith(this.mediaType)) {
            this
        } else {
            throw MediaTypeException("${mediaType} is not ${this.mediaType}")
        }
    }
    public func fromData(data: Data): Array<Byte> {
        let json = (JsonValue.tryFromData(data) as JsonValue).getOrThrow().toString()
        charset.newEncoder().encode(json)
    }
    public func toData(data: Array<Byte>): Data {
        toData(charset.newDecoder().decode(data))
    }
    public func toData(data: String): Data {
        JsonValue.fromStr(data).toData()
    }
}
private let _ = JsonMediaType()