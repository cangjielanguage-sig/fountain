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

import std.collection.concurrent.ConcurrentHashMap

import f_cache.HeapCache

public interface RegexFromString {
    func regex(option!: RegexOption, solid!: Bool): Regex
}
var CACHE = HeapCache<Regex>(maxLife: Duration.day, maxSize: 10000)
var SOLID = ConcurrentHashMap<String, Regex>()
extend String <: RegexFromString {
    public func regex(option!: RegexOption = RegexOption(), solid!: Bool = false): Regex {
        let key = "/${this}/${option.toString()}"
        if (solid) {
            if(let Some(x) <- SOLID.get(key)){
                x
            }else if(let Some(x) <- CACHE.get(key)){
                SOLID[key] = x
                x
            }else{
                let reg = Regex(this, option)
                SOLID[key] = reg
                reg
            }
        } else {
            CACHE.getOrCompute(key) {
                SOLID.get(key) ?? Regex(this, option)
            }.getOrThrow()
        }
    }
}
