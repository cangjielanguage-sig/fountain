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

/** RFC 6154 的系统邮箱属性。 */
public enum SpecialUse <: ToString {
    | All
    | Archive
    | Drafts
    | Flagged
    | Junk
    | Sent
    | Trash
    /** 不是系统邮箱（或属性不认识）。 */
    | Other

    public func toString(): String {
        match (this) {
            case All => "\\All"
            case Archive => "\\Archive"
            case Drafts => "\\Drafts"
            case Flagged => "\\Flagged"
            case Junk => "\\Junk"
            case Sent => "\\Sent"
            case Trash => "\\Trash"
            case Other => ""
        }
    }

    public static func parse(value: String): SpecialUse {
        match (value.toAsciiUpper()) {
            case "\\ALL" => SpecialUse.All
            case "\\ARCHIVE" => SpecialUse.Archive
            case "\\DRAFTS" => SpecialUse.Drafts
            case "\\FLAGGED" => SpecialUse.Flagged
            case "\\JUNK" => SpecialUse.Junk
            case "\\SENT" => SpecialUse.Sent
            case "\\TRASH" => SpecialUse.Trash
            case _ => SpecialUse.Other
        }
    }
}

/**
 * `SPECIAL-USE`（RFC 6154）。
 *
 * 只认属性、**不猜名字**：`Sent Items` / `已发送` / `Sent` 三种写法都存在，
 * 按名称匹配必错。服务器自定义的 `\Foo` 留在 attributes 里，不报错。
 */
public class ImapSpecialUse {
    private let client: ImapClient

    public init(client: ImapClient) {
        this.client = client
    }

    /**
     * `LIST (SPECIAL-USE) "" "*"`。
     *
     * 无 `SPECIAL-USE` 能力时**抛错**，而不是退化成全量 `LIST` 再按名字猜——
     * 猜错的代价是把草稿箱当成已发送。
     */
    public func listSpecialUse(): Array<MailboxInfo> {
        client.requireCapability("SPECIAL-USE")
        client.listInternal("LIST", "", "*", "(SPECIAL-USE)")
    }

    /** 从 attributes 里取第一个系统属性。 */
    public static func specialUseOf(info: MailboxInfo): SpecialUse {
        for (attribute in info.attributes) {
            let parsed = SpecialUse.parse(attribute)
            if (parsed.toString().size > 0) {
                return parsed
            }
        }
        SpecialUse.Other
    }

    /** 把列表按系统属性归类（同一属性取第一个）。 */
    public static func indexBySpecialUse(mailboxes: Array<MailboxInfo>): Array<(SpecialUse, String)> {
        let out = ArrayList<(SpecialUse, String)>()
        let seen = ArrayList<String>()
        for (info in mailboxes) {
            let kind = specialUseOf(info)
            let key = kind.toString()
            if (key.size == 0) {
                continue
            }
            var duplicate = false
            for (existing in seen) {
                if (existing == key) {
                    duplicate = true
                }
            }
            if (!duplicate) {
                seen.add(key)
                out.add((kind, info.name))
            }
        }
        out.toArray()
    }
}
