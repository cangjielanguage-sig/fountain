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

public enum FailureMessageKind <: Equatable<FailureMessageKind> & Parsable<FailureMessageKind> & DataParsable<FailureMessageKind> {
    | Base64Binary
    | Text

    public operator func ==(other: FailureMessageKind) {
        match ((this, other)) {
            case (Base64Binary, Base64Binary) | (Text, Text) => true
            case _ => false
        }
    }
    public static func tryParse(kind: String): ?FailureMessageKind {
        match (kind.toAsciiUpper()) {
            case "BASE64BINARY" => Base64Binary
            case "TEXT" => Text
            case _ => None<FailureMessageKind>
        }
    }
    public static func parse(kind: String): FailureMessageKind {
        tryParse(kind).getOrThrow {MVCException("unsupported FailureMessageKind ${kind}")}
    }
}
