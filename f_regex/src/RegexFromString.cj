/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_regex

import std.collection.HashSet
import std.collection.concurrent.ConcurrentHashMap
import f_base.StringGenerator
import f_cache.HeapCache

public interface RegexFromString {
    func regex(flags!: Array<RegexFlag>, solid!: Bool): Regex
}

private let CACHE = HeapCache<Regex>(maxLife: Duration.day, maxSize: 10000)
private let SOLID = ConcurrentHashMap<String, Regex>()

extend String <: RegexFromString {
    public func regex(flags!: Array<RegexFlag> = [], solid!: Bool = false): Regex {
        func flagstr(flag: RegexFlag): String {
            match (flag) {
                case IgnoreCase => 'i'
                case MultiLine => 'm'
                case Unicode => 'u'
            }
        }
        func flagsstr() {
            let set = HashSet<String>()
            for (f in flags) {
                set.add(flagstr(f))
            }
            let fb = StringGenerator()
            for (f in set) {
                fb.append(f)
            }
            fb.toString()
        }
        let key = "/${this}/${flagsstr()}"
        if (solid) {
            if (let Some(x) <- SOLID.get(key)) {
                x
            } else if (let Some(x) <- CACHE.get(key)) {
                SOLID[key] = x
                x
            } else {
                let reg = Regex(this, flags)
                SOLID[key] = reg
                reg
            }
        } else {
            CACHE.getOrCompute(key) {
                SOLID.get(key) ?? Regex(this, flags)
            }
        }
    }
}
