/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

import std.unicode.{UnicodeRuneExtension, UnicodeStringExtension}

public class Options<T, R> {
    private init() {}

    public static func isEmpty(current: Option<T>): Bool {
        match (current) {
            case Option<T>.None => return true
            case Some(x) where x is Unit => true
            case Some(x) where x is Collection<R> => (x as Collection<R>).getOrThrow().isEmpty()
            case Some(_) => false
        }
    }
    public static func isNotEmpty(current: Option<T>): Bool {
        !isEmpty(current)
    }
    public static func isEmptyOrUnit(current: Option<T>): Bool {
        isEmpty(current) || match (current) {
            case Some(v) => v is Unit
            case Option<T>.None => true
        }
    }
    public static func isNotEmptyOrUnit(current: Option<T>): Bool {
        !isEmptyOrUnit(current)
    }
    public static func isEmptyOrZero(current: Option<T>): Bool {
        isEmpty(current) || match (current) {
            case Some(v) => match (v) {
                case x: Int64 where x == 0 => true
                case x: UInt64 where x == 0 => true
                case x: Int32 where x == 0 => true
                case x: UInt32 where x == 0 => true
                case x: Int16 where x == 0 => true
                case x: UInt16 where x == 0 => true
                case x: Int8 where x == 0 => true
                case x: UInt8 where x == 0 => true
                case x: Float64 where x == 0.0 => true
                case x: Float32 where x == 0.0 => true
                case x: Float16 where x == 0.0 => true
                case x: Rune where x == r'\0' => true
                case x: String where x.isEmpty() || x == '\0' => true
                case _ => false
            }
            case Option<T>.None => true
        }
    }
    public static func isNotEmptyOrZero(current: Option<T>): Bool {
        !isEmptyOrZero(current)
    }
    public static func isEmptyOrBlank(current: Option<T>): Bool {
        func isBlankRune(c: Rune) {
            c == r'\0' || c.isWhiteSpace()
        }
        isEmpty(current) || match (current.getOrThrow()) {
            case v: String => v.isBlank()
            case v: Iterable<Rune> =>
                for (c in v where !isBlankRune(c)) {
                    return false
                }
                true
            case v: Rune => isBlankRune(v)
            case _ => false
        }
    }
    public static func isNotEmptyOrBlank(current: Option<T>): Bool {
        !isEmptyOrBlank(current)
    }
    public static func isEmptyOrZeroOrBlank(current: Option<T>) {
        isEmptyOrZero(current) || isEmptyOrBlank(current)
    }
    public static func isNotEmptyOrZeroOrBlank(current: Option<T>) {
        !isEmptyOrZeroOrBlank(current)
    }
    public static func convert(origin: Option<T>, default: R, converter: (T) -> Option<R>): R {
        convert(origin, converter) ?? default
    }
    public static func convert(origin: Option<T>, default: R): Option<R> {
        convert(origin) ?? default
    }
    public static func convert(origin: Option<T>): Option<R> {
        doConvert(origin, false)
    }
    public static func convertOrThrow(origin: Option<T>, default: R): Option<R> {
        convertOrThrow(origin) ?? default
    }
    public static func convertOrThrow(origin: Option<T>): Option<R> {
        doConvert(origin, true)
    }
    private static func doConvert(origin: Option<T>, toThrow: Bool): Option<R> {
        doConvert(origin, {v => v as R}, toThrow)
    }
    public static func convert(origin: Option<T>, converter: (T) -> Option<R>): Option<R> {
        doConvert(origin, converter, false)
    }
    public static func convertOrThrow(origin: Option<T>, converter: (T) -> Option<R>) {
        doConvert(origin, converter, true)
    }
    private static func doConvert(origin: Option<T>, converter: (T) -> Option<R>, toThrow: Bool): Option<R> {
        if (let Some(v) <- origin) {
            match (converter(v)) {
                case Some(r) => r
                case _ where toThrow => throw IllegalArgumentException()
                case _ => None<R>
            }
        } else {
            None<R>
        }
    }
}
