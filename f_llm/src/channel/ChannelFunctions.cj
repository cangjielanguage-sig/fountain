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
import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_llm.tool.*

@DataAssist[props fields]
public class ChannelAttachmentParam {
    @JsonStringSchema[description: '附件文件名（留空则用路径里的文件名）']
    private var filename: String = ''
    @JsonStringSchema[description: '附件在本机的绝对路径']
    private var path: String = ''
}

@DataAssist[props fields]
public class ChannelSendParam {
    @JsonStringSchema[description: '流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description: '平台名，例如 email']
    private var platform: String = ''
    @JsonStringSchema[description: '账号名；平台只有一个账号时可留空']
    private var account: String = ''
    @JsonStringSchema[description: '收件人']
    private var to: String = ''
    @JsonStringSchema[description: '标题']
    private var subject: String = ''
    @JsonStringSchema[description: '纯文本正文']
    private var text: String = ''
    @JsonStringSchema[description: 'HTML 正文；非空时优先于 text']
    private var html: String = ''
    @JsonArraySchema[description: '附件列表（文件名 + 本机路径）']
    private var attachments: ArrayList<ChannelAttachmentParam> = ArrayList<ChannelAttachmentParam>()
}

@DataAssist[props fields]
public class ChannelInboxParam {
    @JsonStringSchema[description: '流程下一步骤的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description: '平台名，例如 email']
    private var platform: String = ''
    @JsonStringSchema[description: '账号名；平台只有一个账号时可留空']
    private var account: String = ''
    @JsonIntSchema[description: '最多取多少条，默认 10']
    private var limit: Int64 = 10
    @JsonStringSchema[description: '附件下载目录；留空则只返回附件元数据']
    private var downloadDir: String = ''
}

/** 内置函数：经中介者发送一条消息 */
@Bean
public class ChannelSendFunction <: FunctionCalling<ChannelSendParam> {
    public prop name: String {
        get() {
            'channelSend'
        }
    }

    public prop description: String {
        get() {
            '通过第三方平台（email 等）发送消息；支持附件；返回 JSON 结果'
        }
    }

    public func call(params: ChannelSendParam): FunctionResult {
        let attachments = ArrayList<OutboundAttachment>()
        for (item in params.attachments) {
            attachments.add(OutboundAttachment(item.filename, item.path))
        }
        try {
            let receipt = ChannelMediator.send(params.platform, params.account,
                OutboundMessage(params.to, params.subject, text: params.text, html: params.html,
                    attachments: attachments))
            let json = if (receipt.ok) {
                '{\"ok\":true,\"messageId\":${JsonString(receipt.messageId)}}'
            } else {
                '{\"ok\":false,\"error\":${JsonString(receipt.error)}}'
            }
            FunctionResult(event: params.nextEvent, result: json)
        } catch (e: Exception) {
            FunctionResult(event: params.nextEvent, result: '{\"ok\":false,\"error\":${JsonString(e.message)}}')
        }
    }
}

/** 内置函数：经中介者拉取消息 */
@Bean
public class ChannelInboxFunction <: FunctionCalling<ChannelInboxParam> {
    public prop name: String {
        get() {
            'channelInbox'
        }
    }

    public prop description: String {
        get() {
            '通过第三方平台（email 等）拉取最近消息；可指定附件下载目录；返回 JSON 数组'
        }
    }

    public func call(params: ChannelInboxParam): FunctionResult {
        let limit = if (params.limit > 0) {
            params.limit
        } else {
            10
        }
        try {
            let messages = ChannelMediator.receive(params.platform, params.account, limit,
                downloadDir: params.downloadDir)
            FunctionResult(event: params.nextEvent, result: render(messages))
        } catch (e: Exception) {
            FunctionResult(event: params.nextEvent, result: '{\"ok\":false,\"error\":${JsonString(e.message)}}')
        }
    }

    private static func render(messages: ArrayList<InboundMessage>): String {
        var text = '['
        for (index in 0..messages.size) {
            if (index > 0) {
                text += ','
            }
            let message = messages[index]
            text += '{\"id\":${JsonString(message.id)},\"from\":${JsonString(message.from)},'
            text += '\"subject\":${JsonString(message.subject)},\"text\":${JsonString(message.text)},'
            text += '\"receivedAt\":${JsonString(message.receivedAt)},\"unread\":${message.unread},'
            text += '"attachments":['
            for (position in 0..message.attachments.size) {
                if (position > 0) {
                    text += ','
                }
                let item = message.attachments[position]
                text += '{\"filename\":${JsonString(item.filename)},\"size\":${item.size},'
                text += '\"path\":${JsonString(item.path)},\"saved\":${item.saved},'
                text += '\"error\":${JsonString(item.error)}}'
            }
            text += ']}'
        }
        text + ']'
    }
}
