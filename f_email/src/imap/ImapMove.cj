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

/** `MOVE` 的结果。 */
public struct MoveResult {
    /** `true` 表示服务器用一条 `MOVE` 原子完成；`false` 表示走了三步回退。 */
    public let atomic: Bool
    public let copyUid: CopyResult
    /** `* VANISHED`（QRESYNC 生效时才有）。 */
    public let vanished: Array<String>
    /** `* EXPUNGE` 报的序号（未启用 QRESYNC 时）。 */
    public let expunged: Array<Int64>
    /** 回退过程中的降级说明（例如没有 `UIDPLUS` 只能用 `EXPUNGE`）。 */
    public let warnings: Array<String>

    public init(
        atomic: Bool,
        copyUid!: CopyResult = CopyResult(),
        vanished!: Array<String> = [],
        expunged!: Array<Int64> = [],
        warnings!: Array<String> = []
    ) {
        this.atomic = atomic
        this.copyUid = copyUid
        this.vanished = vanished
        this.expunged = expunged
        this.warnings = warnings
    }
}

/**
 * `MOVE`（RFC 6851）与它的非原子回退。
 *
 * 服务器广告 `MOVE` 时一次往返完成"复制 + 标记删除 + 清除"。
 * 没广告时的回退是三步：`UID COPY` → `UID STORE +FLAGS.SILENT (\Deleted)` → `UID EXPUNGE`，
 * 任何一步失败都会留下两份或零份副本，所以**默认不做**；调用方必须显式
 * `allowNonAtomic(true)`，并且 `MoveResult.atomic=false` 会如实回报。
 */
public class ImapMove {
    private let client: ImapClient

    public init(client: ImapClient) {
        this.client = client
    }

    public func move(set: SequenceSet, mailbox: String, allowNonAtomic!: Bool = false): MoveResult {
        moveInternal("MOVE", set, mailbox, allowNonAtomic)
    }

    public func uidMove(set: SequenceSet, mailbox: String, allowNonAtomic!: Bool = false): MoveResult {
        moveInternal("UID MOVE", set, mailbox, allowNonAtomic)
    }

    private func moveInternal(
        prefix: String,
        set: SequenceSet,
        mailbox: String,
        allowNonAtomic: Bool
    ): MoveResult {
        client.requireSelected(prefix)
        if (client.capabilities.supportsMove) {
            let result = client.execute("${prefix} ${set} ${client.encodeMailbox(mailbox)}")
            if (!result.isOk()) {
                throw MailProtocolException("${prefix} 失败：${result.response.raw}")
            }
            let vanished = ArrayList<String>()
            let expunged = ArrayList<Int64>()
            for (untagged in result.untagged) {
                match (untagged.name ?? "") {
                    case "VANISHED" =>
                        for (value in untagged.values) {
                            let text = value.text()
                            if (text.size > 0) {
                                vanished.add(text)
                            }
                        }
                    case "EXPUNGE" =>
                        if (let Some(sequence) <- untagged.numberOf()) {
                            expunged.add(sequence)
                        }
                    case _ => ()
                }
            }
            return MoveResult(
                true,
                copyUid: copyUidOf(result),
                vanished: vanished.toArray(),
                expunged: expunged.toArray()
            )
        }
        if (!allowNonAtomic) {
            throw MailProtocolException(
                "服务器未广告 MOVE；需要允许非原子回退时显式 allowNonAtomic(true)",
                capability: "MOVE"
            )
        }
        return nonAtomicMove(set, mailbox)
    }

    /** 三步回退。中途失败时抛出，调用方据 `MoveResult.atomic=false` 与异常自行对账。 */
    private func nonAtomicMove(set: SequenceSet, mailbox: String): MoveResult {
        let warnings = ArrayList<String>()
        let copy = client.uidCopy(set, mailbox)
        client.store(set, StoreOperation.Add, ["\\Deleted"], silent: true)
        var expunged: Array<Int64> = []
        if (client.capabilities.supportsUidPlus) {
            expunged = client.uidExpunge(set)
        } else {
            warnings.add("服务器无 UIDPLUS，退回 EXPUNGE：会连带删除其它带 \\Deleted 的邮件")
            expunged = client.expunge()
        }
        MoveResult(
            false,
            copyUid: copy,
            expunged: expunged,
            warnings: warnings.toArray()
        )
    }

    private func copyUidOf(result: ImapCommandResult): CopyResult {
        if ((result.code() ?? "") != "COPYUID") {
            return CopyResult()
        }
        let args = result.codeArgs()
        if (args.size < 3) {
            return CopyResult()
        }
        CopyResult(
            uidValidity: ImapParser.parseNumber(args[0]),
            sourceUids: Some(SequenceSet(args[1])),
            destUids: Some(SequenceSet(args[2]))
        )
    }
}
