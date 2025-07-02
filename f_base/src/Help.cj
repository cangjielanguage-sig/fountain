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

abstract sealed class Help {
    public static func convert<T>(options: Array<?T>): ?T {
        for (o in options where o.isSome()) {
            return o
        }
        return None
    }
    public static func convert<T>(options: Array<?String>): String {
        for (o in options) {
            match (o) {
                case Some(x) where x.size > 0 => return x
                case _ => continue
            }
        }
        ''
    }
    public static func convert<T, C>(collections: Array<C>): ?C where C <: Collection<T> {
        for (c in collections where c.size > 0) {
            return c
        }
        return None
    }
    public static func convert(strings: Array<String>): String {
        for (s in strings where s.size > 0) {
            return s
        }
        return ""
    }
}
