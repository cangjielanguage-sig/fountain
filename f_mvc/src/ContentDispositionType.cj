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

public enum ContentDispositionType <: Equatable<ContentDispositionType> & Hashable & ToString & Parsable<ContentDispositionType> {
    | attachment
    | formData
    | inline
    | none

    public func toString(): String {
        match (this) {
            case attachment => "attachment"
            case formData => "form-data"
            case inline => "inline"
            case none => ""
        }
    }
    public func hashCode(): Int64 {
        toString().hashCode()
    }
    public prop isAttachment: Bool {
        get() {
            this == attachment
        }
    }
    public prop isFormData: Bool {
        get() {
            this == formData
        }
    }
    public prop isInline: Bool {
        get() {
            this == inline
        }
    }
    public prop isNone: Bool {
        get() {
            this == none
        }
    }
    public operator func ==(other: ContentDispositionType) {
        match ((this, other)) {
            case (attachment, attachment) | (formData, formData) | (inline, inline) | (none, none) => true
            case _ => false
        }
    }
    public static func tryParse(value: String): Option<ContentDispositionType> {
        match (value) {
            case "attachment" => attachment
            case "formData" | "form-data" => formData
            case "inline" => inline
            case "none" | "" | "None" | "NONE" => none
            case _ => None<ContentDispositionType>
        }
    }
    public static func parse(value: String): ContentDispositionType {
        match (tryParse(value)) {
            case Some(v) => v
            case _ => throw IllegalArgumentException(
                "argument must be one of \"attachment\" \"formData\" \"form-data\" \"inline\" \"none\" \"None\" \"NONE\" \"\", but it is \"${value}\"")
        }
    }
}
