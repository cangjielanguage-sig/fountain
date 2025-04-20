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

public import std.regex.*
import std.collection.ArrayList
import std.convert.Parsable
import f_base.*
import f_exception.UnreachableException
import f_cache.HeapCache
import f_regex.exception.RegexBuilderException

public interface ExtendRegex {
    static prop INTEGER: Regex
    static prop DECIMAL: Regex
    static prop REAL_NUMBER: Regex
    static prop EMAIL: Regex
    static prop DURATION: Regex
    static prop IDENTIFIER: Regex
    static prop BASE64: Regex
    static func wildcard(wildcard: String): Regex
    static func builder(): RegexBuilder
    static func builder(callback: (RegexBuilder) -> Unit): Regex
    func matched(input: String): Bool
    func split(input: String): Array<String>
    func replace(input: String, replacement: String, index!: Int64, matchDataIndex!: Int64): String
    func replaceAll(input: String, replacement: String, index!: Int64, matchDataIndex!: Int64): String

}
extend Regex <: ExtendRegex {
    public static prop INTEGER: Regex{
        get(){
            #"^\d+$"#.regex(solid: true)
        }
    }
    public static prop DECIMAL: Regex{
        get(){
            #"^\d+\.\d+$"#.regex(solid: true)
        }
    }
    public static prop REAL_NUMBER: Regex {
        get() {
            #"^\d+(\.\d*)?$"#.regex(solid: true)
        }
    }
    public static prop EMAIL: Regex{
        get(){
            #"^[\w-]+@[\w-]+(\.[\w-]+)+$"#.regex(solid: true)
        }
    }
    public static prop DURATION: Regex {
        get(){
            #"^-?((\d+)(d|h|m|s|ms|us|ns))+$"#.regex(solid: true)
        }
    }
    public static prop IDENTIFIER: Regex {
        get(){
            #"^_*[a-zA-Z]+\w*$"#.regex(solid: true)
        }
    }
    public static prop BASE64: Regex {
        get(){
            '^([+a-zA-Z0-9/]{4})+([+a-zA-Z0-9/]{2}==|[+a-zA-Z0-9/]{3}=)?$'.regex(solid: true)
        }
    }
    public static func wildcard(wildcard: String): Regex {
        '^${wildcard}$'.replace('.', '\\.').replace('\\.\\.', '(\\.\\w+)#\\.')
        .replace('\\.*\\.', '\\.\\w+\\.').replace('*', '\\w*').replace('?', '\\w?')
        .replace('(\\.\\w+)#\\.', '(\\.\\w+)*\\.').regex()
    }

    public static func builder(): RegexBuilder {
        RegexBuilder()
    }
    public static func builder(callback: (RegexBuilder) -> Unit): Regex {
        var builder = builder()
        callback(builder)
        builder.build()
    }
    public func matched(input: String): Bool {
        matches(input).isSome()
    }
    public func split(input: String): Array<String> {
        this.matcher(input).split()
    }

    public func replace(input: String, replacement: String, index!: Int64 = 0, matchDataIndex!: Int64 = 0): String {
        let matcher = this.matcher(input)
        var i = 0
        var findIdx = index
        while (i < matchDataIndex) {
            match (matcher.find(findIdx)) {
                case Some(md) => findIdx = md.matchPosition().end
                case _ => return input
            }
            i++
        }
        match (matcher.find(findIdx)) {
            case Some(md) =>
                let rr = RegexReplacement(replacement)
                let r = rr.format(md)
                matcher.replace(r, md.matchPosition().start)
            case _ => input
        }
    }
    public func replaceAll(input: String, replacement: String, index!: Int64 = 0, matchDataIndex!: Int64 = 0): String {
        var str = input
        var matcher = this.matcher(str)
        var i = 0
        var findIdx = index
        while (i < matchDataIndex) {
            match (matcher.find(findIdx)) {
                case Some(md) => findIdx = md.matchPosition().end
                case _ => return str
            }
            i++
        }
        let rr = RegexReplacement(replacement)
        while (findIdx < str.size) {
            match (matcher.find(findIdx)) {
                case Some(md) =>
                    let r = rr.format(md)
                    let pos = md.matchPosition().start
                    str = matcher.replace(r, pos)
                    findIdx = pos + r.size
                    if (findIdx < str.size) {
                        matcher = matcher.resetString(str)
                    } else {
                        break
                    }
                case _ => break
            }
        }
        str
    }
}
public class RegexReplacement {
    private let parts = ArrayList<Any>()
    public init(replacement: String) {
        let part = StringBuilder()
        var placeholder = false
        for (ch in replacement.runes()) {
            match (ch) {
                case r'$' =>
                    if (part.size > 0) {
                        parts.add(part.toString())
                        part.reset()
                    }
                    placeholder = true
                case _ where placeholder && ch >= r'0' && ch <= r'9' => part.append(ch)
                case _ where placeholder =>
                    if (part.size > 0) {
                        let idx = Int64.parse(part.toString())
                        parts.add(idx)
                        part.reset()
                    } else {
                        parts.add("$")
                    }
                    placeholder = false
                case _ => part.append(ch)
            }
        }
        if (replacement.endsWith("$")) {
            parts.add("$")
        } else if (part.size > 0) {
            parts.add(part.toString())
        }
    }
    func format(data: MatchData): String {
        let builder = StringBuilder()
        var i = 0
        while (i < parts.size) {
            match (parts[i]) {
                case x: String => builder.append(x)
                case x: Int64 => builder.append(data.matchStr(x))
                case _ => throw UnreachableException()
            }
            i++
        }
        builder.toString()
    }
}
