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
package fountain::f_llm.channel

import std.collection.*

/** 平台名常量：已实现的只有 email，其余为预留（不注册 provider，调用即报不支持） */
public struct ChannelPlatforms {
    public static const EMAIL = 'email'
    public static const WECHAT = 'wechat'
    public static const WECOM = 'wecom'
    public static const DINGTALK = 'dingtalk'
    public static const FEISHU = 'feishu'

    private init() {
    }

    /** 预留但尚未实现的平台 */
    public static func isReserved(name: String): Bool {
        let key = name.trimAscii().toAsciiLower()
        key == WECHAT || key == WECOM || key == DINGTALK || key == FEISHU
    }
}

/** 通道相关错误（寻址失败、平台不支持、transport 失败） */
public class ChannelException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/** 发送附件：给本地文件路径，不搬字节（大文件塞进 JSON 会被工具结果上限截断） */
public class OutboundAttachment {
    public let filename: String
    public let path: String

    public init(filename: String, path: String) {
        this.filename = if (filename.trimAscii().isEmpty()) {
            path
        } else {
            filename
        }
        this.path = path
    }
}

public class OutboundMessage {
    public let to: String
    public let subject: String
    public let text: String
    public let html: String
    public let attachments: ArrayList<OutboundAttachment>

    public init(to: String, subject: String, text!: String = '', html!: String = '',
        attachments!: ArrayList<OutboundAttachment> = ArrayList<OutboundAttachment>()) {
        this.to = to
        this.subject = subject
        this.text = text
        this.html = html
        this.attachments = attachments
    }
}

/** 接收附件：默认只给元数据；指定下载目录后 `saved=true` 且 `path` 有值 */
public class InboundAttachment {
    public let filename: String
    public let size: Int64
    public let path: String
    public let saved: Bool
    public let error: String

    public init(filename: String, size: Int64, path!: String = '', saved!: Bool = false, error!: String = '') {
        this.filename = filename
        this.size = size
        this.path = path
        this.saved = saved
        this.error = error
    }
}

public class InboundMessage {
    public let id: String
    public let from: String
    public let subject: String
    public let text: String
    public let receivedAt: String
    public let unread: Bool
    public let attachments: ArrayList<InboundAttachment>

    public init(id: String, from: String, subject: String, text!: String = '', receivedAt!: String = '',
        unread!: Bool = false, attachments!: ArrayList<InboundAttachment> = ArrayList<InboundAttachment>()) {
        this.id = id
        this.from = from
        this.subject = subject
        this.text = text
        this.receivedAt = receivedAt
        this.unread = unread
        this.attachments = attachments
    }
}

public class SendReceipt {
    public let ok: Bool
    public let messageId: String
    public let error: String

    public init(ok: Bool, messageId!: String = '', error!: String = '') {
        this.ok = ok
        this.messageId = messageId
        this.error = error
    }

    public static func success(messageId!: String = ''): SendReceipt {
        SendReceipt(true, messageId: messageId)
    }

    public static func failure(error: String): SendReceipt {
        SendReceipt(false, error: error)
    }
}

/** 一个平台的账号配置（由 `llm_channels` 的一条记录解析而来） */
public class ChannelAccountConf {
    public let platform: String
    public let account: String
    public let from: String
    public let user: String
    public let password: String
    public let smtpHost: String
    public let smtpPort: UInt16
    public let imapHost: String
    public let imapPort: UInt16
    public let tls: String
    public let extra: HashMap<String, String>

    public init(platform: String, account!: String = '', from!: String = '', user!: String = '', password!: String = '',
        smtpHost!: String = '', smtpPort!: UInt16 = 465, imapHost!: String = '', imapPort!: UInt16 = 993,
        tls!: String = '', extra!: HashMap<String, String> = HashMap<String, String>()) {
        this.platform = platform
        this.account = account
        this.from = from
        this.user = user
        this.password = password
        this.smtpHost = smtpHost
        this.smtpPort = smtpPort
        this.imapHost = imapHost
        this.imapPort = imapPort
        this.tls = tls
        this.extra = extra
    }
}

/** 平台无关的消息通道 */
public interface Channel {
    /** 平台名（如 `email`） */
    prop platform: String
    /** 账号名；同平台多账号靠它区分，可为空（默认账号） */
    prop account: String
    /** 发送一条消息；失败用 `SendReceipt` 表达，不抛未捕获异常 */
    func send(message: OutboundMessage): SendReceipt
    /** 拉取最近 `limit` 条；`downloadDir` 非空时附件落盘 */
    func receive(limit: Int64, downloadDir: String): ArrayList<InboundMessage>
    /** 释放底层连接 */
    func close(): Unit
}
