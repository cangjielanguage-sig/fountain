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

import fountain::f_email.model.MailProtocolException

/** QRESYNC 的 `SELECT` 参数。 */
public struct QResyncParams <: ToString {
    public let uidValidity: Int64
    public let modseq: Int64
    /** 已知的 UID 集合；`None` 表示不带（服务器会当作"全新客户端"）。 */
    public let knownUids: ?SequenceSet
    /** 已知的序号集合与对应 UID 集合。 */
    public let knownSeqs: ?SequenceSet
    public let knownSeqUids: ?SequenceSet

    public init(
        uidValidity: Int64,
        modseq: Int64,
        knownUids!: ?SequenceSet = None,
        knownSeqs!: ?SequenceSet = None,
        knownSeqUids!: ?SequenceSet = None
    ) {
        this.uidValidity = uidValidity
        this.modseq = modseq
        this.knownUids = knownUids
        this.knownSeqs = knownSeqs
        this.knownSeqUids = knownSeqUids
    }

    public func toString(): String {
        var text = "${uidValidity} ${modseq}"
        if (let Some(uids) <- knownUids) {
            text = text + " ${uids}"
            if (let Some(seqs) <- knownSeqs) {
                let uids2 = match (knownSeqUids) {
                    case Some(value) => value.toString()
                    case None => ""
                }
                text = text + " (${seqs} ${uids2})"
            }
        }
        text
    }
}

/**
 * `CONDSTORE` / `QRESYNC`（RFC 7162）。
 *
 * `HIGHESTMODSEQ` 是邮箱级版本号：`FETCH (CHANGEDSINCE n)` 拿增量，
 * `STORE (UNCHANGEDSINCE n)` 做乐观并发控制。后者部分失败时服务器回
 * `* OK [MODIFIED <set>]`，这些项 MUST NOT 被当成成功——见 [StoreResult.modified]。
 */
public class ImapCondStore {
    private let client: ImapClient

    public init(client: ImapClient) {
        this.client = client
    }

    /**
     * 带 `CONDSTORE` 的 `SELECT`；给了 [qresync] 就走 `QRESYNC`。
     *
     * 两者都要先 `ENABLE`（`QRESYNC` 蕴含 `CONDSTORE`，不要重复 `ENABLE`），
     * 因为 `SELECT` 的参数只在服务器已接受该扩展时才合法。
     */
    public func select(mailbox: String, qresync!: ?QResyncParams = None): MailboxStatus {
        match (qresync) {
            case Some(params) =>
                client.requireEnabled("QRESYNC")
                client.selectInternal(mailbox, "SELECT", "(QRESYNC (${params}))")
            case None =>
                client.requireEnabled("CONDSTORE")
                client.selectInternal(mailbox, "SELECT", "(CONDSTORE)")
        }
    }

    public func fetchChangedSince(
        set: SequenceSet,
        since: Int64,
        items: Array<FetchItem>
    ): Array<FetchResult> {
        client.requireEnabled("CONDSTORE")
        client.fetchWithSuffix("FETCH", set, items, " (CHANGEDSINCE ${since})")
    }

    public func uidFetchChangedSince(
        set: SequenceSet,
        since: Int64,
        items: Array<FetchItem>
    ): Array<FetchResult> {
        client.requireEnabled("CONDSTORE")
        client.fetchWithSuffix("UID FETCH", set, items, " (CHANGEDSINCE ${since})")
    }

    /**
     * `STORE (UNCHANGEDSINCE n)`。
     *
     * 冲突的序号进 `StoreResult.modified`，**不出现在 `updated` 里**。
     */
    public func storeUnchangedSince(
        set: SequenceSet,
        operation: StoreOperation,
        flags: Array<String>,
        since: Int64,
        silent!: Bool = false
    ): StoreResult {
        client.requireEnabled("CONDSTORE")
        client.store(set, operation, flags, silent: silent, unchangedSince: Some(since))
    }

    /** `* VANISHED (EARLIER)` 与普通 `* VANISHED` 都取走。 */
    public func takeVanished(): Array<String> {
        client.takeVanished()
    }

    public func requireSupported(): Unit {
        if (!client.capabilities.supportsCondStore && !client.capabilities.supportsQResync) {
            throw MailProtocolException("服务器未广告 CONDSTORE/QRESYNC 能力", capability: "CONDSTORE")
        }
    }
}
