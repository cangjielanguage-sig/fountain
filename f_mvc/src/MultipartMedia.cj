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

public class MultipartMedia <: Multipart {
    public MultipartMedia(
        contentDisposition: ContentDisposition,
        public let mediaType: MediaType,
        public let bytes: Array<Byte>
    ) {
        super(contentDisposition)
    }

    public func toData(): Data {
        mediaType.toData(bytes)
    }
    public func toDataFields<T>(): T where T <: DataFields<T> {
        mediaType.toDataFields<T>(bytes)
    }
    public func toText(): String {
        let charset = contentDisposition.getCharset() ?? Charsets.UTF8
        charset.newDecoder().decode(bytes)
    }
    public func to<T>(): ?T where T <: Parsable<T> {
        T.tryParse(toText())
    }
}
