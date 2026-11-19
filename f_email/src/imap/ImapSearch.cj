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
package fountain::f_email.imap

import std.collection.ArrayList
import fountain::f_email.model.MailProtocolException

/**
 * `SEARCH` 条件。
 *
 * 组合只有三种形状（RFC 3501 第 6.4.4 节）：`AND` 是多条件平铺，`OR` 必须二元，
 * `NOT` 取反且只作用于紧邻的一条。因此这里不暴露任意树，只给
 * [andWith] / [orWith] / [negate] 三个构造器——想拼一棵怪树时自然会被语言挡住。
 *
 * 字符集：只有 `contains` 系列的**值**含非 ASCII 时才需要 `CHARSET UTF-8`；
 * 条件名本身恒为 ASCII。
 */
public class SearchCriteria <: ToString {
    private let command: String

    private init(command: String) {
        this.command = command
    }

    public func toString(): String {
        command
    }

    /** 条件里是否出现非 ASCII（决定要不要带 `CHARSET UTF-8`）。 */
    public func needsUtf8(): Bool {
        for (b in command.toArray()) {
            if (b > 126) {
                return true
            }
        }
        false
    }

    // ---------- 组合 ----------

    public func andWith(other: SearchCriteria): SearchCriteria {
        SearchCriteria("${command} ${other.command}")
    }

    public func orWith(other: SearchCriteria): SearchCriteria {
        SearchCriteria("OR ${command} ${other.command}")
    }

    public func negate(): SearchCriteria {
        SearchCriteria("NOT ${command}")
    }

    public static func andAll(criteria: Array<SearchCriteria>): SearchCriteria {
        if (criteria.size == 0) {
            return all()
        }
        var out = ""
        for (criterion in criteria) {
            if (out.size > 0) {
                out = out + " "
            }
            out = out + criterion.command
        }
        SearchCriteria(out)
    }

    public static func orAny(criteria: Array<SearchCriteria>): SearchCriteria {
        if (criteria.size == 0) {
            return all()
        }
        var current = criteria[0]
        for (i in 1..criteria.size) {
            current = current.orWith(criteria[i])
        }
        current
    }

    // ---------- 基本条件 ----------

    public static func all(): SearchCriteria {
        SearchCriteria("ALL")
    }

    public static func unseen(): SearchCriteria {
        SearchCriteria("UNSEEN")
    }

    public static func seen(): SearchCriteria {
        SearchCriteria("SEEN")
    }

    public static func answered(): SearchCriteria {
        SearchCriteria("ANSWERED")
    }

    public static func unanswered(): SearchCriteria {
        SearchCriteria("UNANSWERED")
    }

    public static func flagged(): SearchCriteria {
        SearchCriteria("FLAGGED")
    }

    public static func unflagged(): SearchCriteria {
        SearchCriteria("UNFLAGGED")
    }

    public static func deleted(): SearchCriteria {
        SearchCriteria("DELETED")
    }

    public static func undeleted(): SearchCriteria {
        SearchCriteria("UNDELETED")
    }

    public static func draft(): SearchCriteria {
        SearchCriteria("DRAFT")
    }

    public static func undraft(): SearchCriteria {
        SearchCriteria("UNDRAFT")
    }

    public static func recent(): SearchCriteria {
        SearchCriteria("RECENT")
    }

    public static func old(): SearchCriteria {
        SearchCriteria("OLD")
    }

    public static func newMessages(): SearchCriteria {
        SearchCriteria("NEW")
    }

    public static func keyword(name: String): SearchCriteria {
        SearchCriteria("KEYWORD ${ImapParser.param(name)}")
    }

    public static func unkeyword(name: String): SearchCriteria {
        SearchCriteria("UNKEYWORD ${ImapParser.param(name)}")
    }

    /** `FROM "x"`：匹配 From 头。 */
    public static func from(value: String): SearchCriteria {
        SearchCriteria("FROM ${ImapParser.quoted(value)}")
    }

    public static func to(value: String): SearchCriteria {
        SearchCriteria("TO ${ImapParser.quoted(value)}")
    }

    public static func cc(value: String): SearchCriteria {
        SearchCriteria("CC ${ImapParser.quoted(value)}")
    }

    public static func bcc(value: String): SearchCriteria {
        SearchCriteria("BCC ${ImapParser.quoted(value)}")
    }

    public static func subject(value: String): SearchCriteria {
        SearchCriteria("SUBJECT ${ImapParser.quoted(value)}")
    }

    public static func body(value: String): SearchCriteria {
        SearchCriteria("BODY ${ImapParser.quoted(value)}")
    }

    /** `TEXT`：头部 + 正文全域搜索。 */
    public static func text(value: String): SearchCriteria {
        SearchCriteria("TEXT ${ImapParser.quoted(value)}")
    }

    public static func header(name: String, value: String): SearchCriteria {
        SearchCriteria("HEADER ${ImapParser.quoted(name)} ${ImapParser.quoted(value)}")
    }

    /** `SINCE 1-Jan-2020` 这类日期条件：按邮件内部日期比较（含当天）。 */
    public static func since(date: String): SearchCriteria {
        SearchCriteria("SINCE ${requireDate(date)}")
    }

    public static func before(date: String): SearchCriteria {
        SearchCriteria("BEFORE ${requireDate(date)}")
    }

    public static func on(date: String): SearchCriteria {
        SearchCriteria("ON ${requireDate(date)}")
    }

    public static func sentSince(date: String): SearchCriteria {
        SearchCriteria("SENTSINCE ${requireDate(date)}")
    }

    public static func sentBefore(date: String): SearchCriteria {
        SearchCriteria("SENTBEFORE ${requireDate(date)}")
    }

    public static func larger(bytes: Int64): SearchCriteria {
        SearchCriteria("LARGER ${bytes}")
    }

    public static func smaller(bytes: Int64): SearchCriteria {
        SearchCriteria("SMALLER ${bytes}")
    }

    public static func uid(set: SequenceSet): SearchCriteria {
        SearchCriteria("UID ${set}")
    }

    /** 序号集合条件（`1:5`）。 */
    public static func sequence(set: SequenceSet): SearchCriteria {
        SearchCriteria("${set}")
    }

    /**
     * 日期字面量校验。
     *
     * 只接受 `d-Mon-yyyy`：把 `2020-01-01` 直接发出去，服务器会回 `BAD`，
     * 错误信息还看不出是哪个参数错了。这里本地就拒掉，报错更准。
     */
    private static func requireDate(date: String): String {
        let parts = date.split("-")
        if (parts.size != 3) {
            throw MailProtocolException("SEARCH 日期必须是 d-Mon-yyyy 形式：${date}")
        }
        let day = ImapParser.parseNumber(parts[0])
        let year = ImapParser.parseNumber(parts[2])
        if (day.isNone() || year.isNone()) {
            throw MailProtocolException("SEARCH 日期必须是 d-Mon-yyyy 形式：${date}")
        }
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let month = parts[1].toAsciiUpper()
        var known = false
        for (name in months) {
            if (name == month) {
                known = true
            }
        }
        if (!known) {
            throw MailProtocolException("SEARCH 日期的月份非法：${date}")
        }
        "${day.getOrThrow()}-${month}-${year.getOrThrow()}"
    }
}
