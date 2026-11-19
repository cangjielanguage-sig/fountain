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

import std.io.InputStream

/** 五种传输编码。 */
public enum TransferEncoding <: ToString {
    | SevenBit
    | EightBit
    | Binary
    | QuotedPrintable
    | Base64

    public func toString(): String {
        match (this) {
            case SevenBit => "7bit"
            case EightBit => "8bit"
            case Binary => "binary"
            case QuotedPrintable => "quoted-printable"
            case Base64 => "base64"
        }
    }

    /** 缺失时按 RFC 2045 默认 `7bit`；无法识别按 `7bit` 处理并告警。 */
    public static func parse(value: ?String): TransferEncoding {
        match (value) {
            case Some(raw) =>
                match (raw.trimAscii().toAsciiLower()) {
                    case "7bit" => SevenBit
                    case "8bit" => EightBit
                    case "binary" => Binary
                    case "quoted-printable" => QuotedPrintable
                    case "base64" => Base64
                    case _ => SevenBit
                }
            case None => SevenBit
        }
    }
}

/** 把编码后的字节流还原。 */
public class TransferDecoder {
    public static func stream(
        input: InputStream,
        encoding: TransferEncoding,
        strict!: Bool = false
    ): InputStream {
        match (encoding) {
            case TransferEncoding.Base64 => Base64Decoder(input, strict: strict)
            case TransferEncoding.QuotedPrintable => QuotedPrintableDecoder(input, strict: strict)
            case _ => input
        }
    }
}
