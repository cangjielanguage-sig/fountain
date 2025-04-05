/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean

/**
 * 字符串满足指定条件返回true
 */
public enum StringCond <: Equatable<StringCond> & Equatable<String> {
    /**
     * 忽略本条件
     */
    | IgnoreCond
    /**
     * 传入on的字符串等于指定字符串
     */
    | Exactly(String)
    /**
     * 传入on的字符串以指定字符串开头
     */
    | Prefix(String)
    /**
     * 传入on的字符串以指定字符串结尾
     */
    | Suffix(String)
    /**
     * 传入on的字符串符合通配规则
     */
    | Wildcard(String)
    /**
     * 传入on的字符串符合指定正则表达式
     */
    | Regexp(String)

    public func on(s: String): Bool {
        match (this) {
            case IgnoreCond => true
            case Exactly(v) => s == v
            case Prefix(v) => s.startsWith(v)
            case Suffix(v) => s.endsWith(v)
            case Wildcard(v) => toRegex(v).matched(s)
            case Regexp(v) => v.regex().matched(s)
        }
    }
    public prop ignored: Bool {
        get() {
            match (this) {
                case IgnoreCond => true
                case _ => false
            }
        }
    }
    public operator func ==(right: StringCond) {
        match ((this, right)) {
            case (IgnoreCond, IgnoreCond) => true
            case (Exactly(a), Exactly(b)) => a == b
            case (Prefix(a), Prefix(b)) => a == b
            case (Suffix(a), Suffix(b)) => a == b
            case (Wildcard(a), Wildcard(b)) => a == b
            case (Regexp(a), Regexp(b)) => a == b
            case _ => false
        }
    }
    public operator func ==(right: String) {
        this == Exactly(right)
    }
}
