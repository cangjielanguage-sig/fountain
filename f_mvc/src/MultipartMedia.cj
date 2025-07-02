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

public class MultipartMedia <: Multipart & Data & DataFields<MultipartMedia> {
    public MultipartMedia(
        contentDisposition: ContentDisposition,
        public let mediaType: ?MediaType,
        public let bytes: Array<Byte>
    ) {
        super(contentDisposition)
    }
    public func toData(): Data {
        match (mediaType) {
            case Some(x) => x.toData(bytes)
            case _ => toString().toData()
        }
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        throw MVCException('Not Supported')
    }
    public func toDataFields<T>(): T where T <: DataFields<T> {
        (mediaType?.toDataFields<T>(bytes)).getOrThrow()
    }
    public func toString(): String {
        let charset = contentDisposition.getCharset() ?? Charsets.UTF8
        charset.newDecoder().decode(bytes)
    }
    public static func parse(string: String): Data {
        tryParse(string).getOrThrow()
    }
    public static func tryParse(string: String): ?Data {
        throw MVCException('Not Supported')
    }
    public func to<T>(): ?T where T <: Parsable<T> {
        T.tryParse(toString())
    }
}
