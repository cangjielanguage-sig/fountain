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
import fountain::f_data.*
import fountain::f_llm.config.LLMConfig

/** 装配结果：装上了几个账号、跳过几条、每条跳过的原因 */
public class ChannelInstallReport {
    public var installed: Int64 = 0
    public var skipped: Int64 = 0
    public var errors: ArrayList<String> = ArrayList<String>()

    public init() {
    }

    public func summary(): String {
        'channel install: installed=${installed}, skipped=${skipped}'
    }
}

/**
 * 按 `llm_channels` 装配通道实例。
 *
 * 单条非法只跳过该条，不中断启动——库/凭据比应用晚就绪是常态。
 */
public class ChannelBootstrap {
    private init() {
    }

    /** 解析 JSON 数组并逐条建实例；返回装配报告 */
    public static func install(json: String): ChannelInstallReport {
        let report = ChannelInstallReport()
        let text = json.trimAscii()
        if (text.isEmpty()) {
            return report
        }
        var entries: ArrayList<JsonValue> = ArrayList<JsonValue>()
        try {
            for (item in JsonValue.fromStr(text).asArray()) {
                entries.add(item)
            }
        } catch (e: Exception) {
            report.errors.add('invalid llm_channels json: ${e.message}')
            return report
        }
        for (entry in entries) {
            try {
                let obj = entry.asObject()
                let platform = strOf(obj, 'platform')
                if (platform.trimAscii().isEmpty()) {
                    throw ChannelException('channel entry missing platform')
                }
                let conf = ChannelAccountConf(platform, account: strOf(obj, 'account'), from: strOf(obj, 'from'),
                    user: strOf(obj, 'user'), password: strOf(obj, 'password'), smtpHost: strOf(obj, 'smtpHost'),
                    smtpPort: portOf(obj, 'smtpPort', 465), imapHost: strOf(obj, 'imapHost'),
                    imapPort: portOf(obj, 'imapPort', 993), tls: strOf(obj, 'tls'))
                validate(conf)
                let channel = ChannelMediator.create(conf)
                ChannelMediator.register(channel)
                report.installed++
            } catch (e: Exception) {
                report.skipped++
                report.errors.add(e.message)
            }
        }
        report
    }

    /** 读配置项 `llm_channels` 再装配；配置源异常也转成报告里的错误，不中断装配 */
    public static func installFromConfig(): ChannelInstallReport {
        try {
            install(LLMConfig.channelsJson())
        } catch (e: Exception) {
            let report = ChannelInstallReport()
            report.errors.add('read llm_channels failed: ${e.message}')
            report
        }
    }

    private static func strOf(args: JsonObject, key: String): String {
        match (args.get(key)) {
            case Some(value) => match (value as JsonString) {
                case Some(text) => text.value
                // null 是「没给」，不能变成字面量 "null"
                case None =>
                    if (value is JsonNull) {
                        ''
                    } else {
                        value.toString()
                    }
            }
            case None => ''
        }
    }

    /**
     * 必填与取值校验：宁可跳过一条并记错，也不要装上一个「能创建、一用就炸」的实例。
     *
     * 目前只有 email 有实现，其它平台的校验留给 provider 自己（`create` 会报「不支持」）。
     */
    private static func validate(conf: ChannelAccountConf): Unit {
        if (conf.platform.trimAscii().toAsciiLower() != ChannelPlatforms.EMAIL) {
            return
        }
        if (conf.smtpHost.trimAscii().isEmpty()) {
            throw ChannelException('channel entry missing smtpHost')
        }
        if (conf.user.trimAscii().isEmpty()) {
            throw ChannelException('channel entry missing user')
        }
        let tls = conf.tls.trimAscii().toAsciiLower()
        if (!tls.isEmpty() && tls != 'ssl') {
            throw ChannelException('channel tls=${conf.tls} is not supported yet (only default SSL)')
        }
    }

    private static func portOf(args: JsonObject, key: String, fallback: UInt16): UInt16 {
        let text = strOf(args, key).trimAscii()
        if (text.isEmpty()) {
            return fallback
        }
        match (Int64.tryParse(text)) {
            case Some(number) =>
                if (number < 1 || number > 65535) {
                    throw ChannelException('channel ${key} out of range: ${text}')
                }
                return UInt16(number)
            case None => throw ChannelException('channel ${key} must be a number: ${text}')
        }
    }
}
