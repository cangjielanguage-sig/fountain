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
import fountain::f_email.model.{LimitKind, MailLimitException, MailProtocolException}

/** `SORT` 的排序键（RFC 5256 第 4.2 节）。 */
public enum SortCriterion <: ToString {
    | Arrival
    | Cc
    | Date
    | From
    | Size
    | Subject
    | To

    public func toString(): String {
        match (this) {
            case Arrival => "ARRIVAL"
            case Cc => "CC"
            case Date => "DATE"
            case From => "FROM"
            case Size => "SIZE"
            case Subject => "SUBJECT"
            case To => "TO"
        }
    }
}

/** 排序键 + 是否降序。 */
public struct SortKey {
    public let criterion: SortCriterion
    public let reverse: Bool

    public init(criterion: SortCriterion, reverse!: Bool = false) {
        this.criterion = criterion
        this.reverse = reverse
    }

    public func toString(): String {
        if (reverse) {
            "REVERSE ${criterion}"
        } else {
            criterion.toString()
        }
    }
}

/** `THREAD` 的算法。 */
public enum ThreadAlgorithm <: ToString {
    | OrderedSubject
    | References

    public func toString(): String {
        match (this) {
            case OrderedSubject => "ORDEREDSUBJECT"
            case References => "REFERENCES"
        }
    }

    public func capability(): String {
        match (this) {
            case OrderedSubject => "THREAD=ORDEREDSUBJECT"
            case References => "THREAD=REFERENCES"
        }
    }
}

/** 一棵线程树节点。 */
public struct ThreadNode {
    public let sequence: Int64
    public let children: Array<ThreadNode>

    public init(sequence: Int64, children!: Array<ThreadNode> = []) {
        this.sequence = sequence
        this.children = children
    }

    /** 前序遍历出的序号序列，便于断言。 */
    public func flatten(): Array<Int64> {
        let out = ArrayList<Int64>()
        out.add(sequence)
        for (child in children) {
            for (value in child.flatten()) {
                out.add(value)
            }
        }
        out.toArray()
    }
}

/**
 * `SORT` / `THREAD`（RFC 5256）。
 *
 * 字符集只允许 `US-ASCII` 与 `UTF-8`：RFC 5256 要求服务器 MUST 支持这两者，
 * 客户端既不做转换也不发别的字符集。`UTF8=ACCEPT` 只影响邮箱名与 `SEARCH`，
 * 不改变这里的参数。
 */
public class ImapSort {
    private let client: ImapClient

    public init(client: ImapClient) {
        this.client = client
    }

    public func sort(keys: Array<SortKey>, charset: String, criteria: SearchCriteria): Array<Int64> {
        sortInternal("SORT", keys, charset, criteria)
    }

    public func uidSort(keys: Array<SortKey>, charset: String, criteria: SearchCriteria): Array<Int64> {
        sortInternal("UID SORT", keys, charset, criteria)
    }

    private func sortInternal(
        prefix: String,
        keys: Array<SortKey>,
        charset: String,
        criteria: SearchCriteria
    ): Array<Int64> {
        client.requireCapability("SORT")
        client.requireSelected(prefix)
        let keysText = renderKeys(keys)
        let result = client.execute("${prefix} (${keysText}) ${requireCharset(charset)} ${criteria}")
        if (!result.isOk()) {
            throw MailProtocolException("${prefix} 失败：${result.response.raw}")
        }
        let out = ArrayList<Int64>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "SORT") {
                for (value in untagged.values) {
                    if (let Some(number) <- value.number()) {
                        out.add(number)
                    }
                }
            }
        }
        out.toArray()
    }

    public func thread(algorithm: ThreadAlgorithm, charset: String, criteria: SearchCriteria): Array<ThreadNode> {
        threadInternal("THREAD", algorithm, charset, criteria)
    }

    public func uidThread(
        algorithm: ThreadAlgorithm,
        charset: String,
        criteria: SearchCriteria
    ): Array<ThreadNode> {
        threadInternal("UID THREAD", algorithm, charset, criteria)
    }

    private func threadInternal(
        prefix: String,
        algorithm: ThreadAlgorithm,
        charset: String,
        criteria: SearchCriteria
    ): Array<ThreadNode> {
        // 只广告一种算法时请求另一种必须报错，不能悄悄换成另一种给出"看起来对"的树
        let needed = algorithm.capability()
        if (!client.capabilities.supports(needed)) {
            throw MailProtocolException(
                "服务器未广告 ${needed}，不能改用另一种算法",
                capability: needed
            )
        }
        client.requireSelected(prefix)
        let result = client.execute("${prefix} ${algorithm} ${requireCharset(charset)} ${criteria}")
        if (!result.isOk()) {
            throw MailProtocolException("${prefix} 失败：${result.response.raw}")
        }
        let out = ArrayList<ThreadNode>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "THREAD") {
                for (value in untagged.values) {
                    out.add(parseThread(value, 0))
                }
            }
        }
        out.toArray()
    }

    /**
     * `* THREAD (3 6 (4 23)(44 7 96))` 的解析规则：
     *
     * - 列表第一个数字是根；
     * - 后续**数字**延长这条链（子节点是前一个数字的子节点）；
     * - 后续**子列表**挂到当前链尾，彼此是兄弟。
     */
    static func parseThread(value: ImapValue, depth: Int64): ThreadNode {
        toNode(buildThread(value, depth))
    }

    private static func buildThread(value: ImapValue, depth: Int64): ThreadBuilder {
        if (depth > ImapParser.MAX_DEPTH) {
            throw MailLimitException(LimitKind.Depth, ImapParser.MAX_DEPTH, depth)
        }
        let items = value.items()
        if (items.size == 0) {
            return ThreadBuilder(0)
        }
        let root = ThreadBuilder(items[0].number() ?? 0)
        var current = root
        var index = 1
        while (index < items.size) {
            match (items[index]) {
                case List(_) => current.children.add(buildThread(items[index], depth + 1))
                case _ =>
                    let child = ThreadBuilder(items[index].number() ?? 0)
                    current.children.add(child)
                    current = child
            }
            index += 1
        }
        root
    }

    private static func toNode(builder: ThreadBuilder): ThreadNode {
        let children = ArrayList<ThreadNode>()
        for (child in builder.children) {
            children.add(toNode(child))
        }
        ThreadNode(builder.sequence, children: children.toArray())
    }

    private func renderKeys(keys: Array<SortKey>): String {
        if (keys.size == 0) {
            throw MailProtocolException("SORT 至少需要一个排序键")
        }
        var out = ""
        var first = true
        for (key in keys) {
            if (!first) {
                out = out + " "
            }
            // SORT=DISPLAY 的 DISPLAY FROM / DISPLAY TO 通过 SortCriterion 之外的调用方拼装；
            // 这里只保证基础键与 REVERSE 前缀
            out = out + key.toString()
            first = false
        }
        out
    }

    private func requireCharset(charset: String): String {
        let upper = charset.toAsciiUpper()
        if (upper != "US-ASCII" && upper != "UTF-8") {
            throw MailProtocolException("SORT/THREAD 只允许 US-ASCII 与 UTF-8，收到 ${charset}")
        }
        upper
    }
}

class ThreadBuilder {
    let sequence: Int64
    let children = ArrayList<ThreadBuilder>()

    init(sequence: Int64) {
        this.sequence = sequence
    }
}
