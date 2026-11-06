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
import std.sort.*
import std.sync.*

/**
 * 第三方平台的统一入口（中介者）。
 *
 * 两段式：
 * - **provider**：平台名 → 工厂，由各实现在模块加载时用顶层 `let` 自动注册
 *   （Cangjie 没有 static initializer，本仓既有写法就是文件顶层 `let _x = register(...)`）；
 * - **实例**：由 `ChannelBootstrap` 按 `llm_channels` 为每个账号创建后 `register` 进来，
 *   账号是运行期数据，不该编进静态块。
 *
 * 寻址键是 `(platform, account)`；`account` 留空时，只有该平台**恰好一个**实例才回落，
 * 多账号时直接报错（不猜）。
 */
public class ChannelMediator {
    private static let mutex: Mutex = Mutex()
    private static let providers: HashMap<String, (ChannelAccountConf) -> Channel> = HashMap<String, (ChannelAccountConf) -> Channel>()
    private static let instances: HashMap<String, Channel> = HashMap<String, Channel>()

    private init() {
    }

    private static func normalize(value: String): String {
        value.trimAscii().toAsciiLower()
    }

    private static func keyOf(platform: String, account: String): String {
        '${normalize(platform)}\u{0001}${normalize(account)}'
    }

    /**
     * 注册平台 provider（模块加载时自动调用，业务方不需要手写）。
     *
     * @return true 表示本次真正注册；同名平台已存在时返回 false，**不覆盖**先注册项
     */
    public static func registerProvider(platform: String, factory: (ChannelAccountConf) -> Channel): Bool {
        let name = normalize(platform)
        if (name.isEmpty()) {
            throw ChannelException('channel platform must not be blank')
        }
        var added = false
        synchronized(mutex) {
            if (!providers.contains(name)) {
                providers[name] = factory
                added = true
            }
        }
        added
    }

    /** 已实现平台（不含预留平台名） */
    public static func providerPlatforms(): ArrayList<String> {
        let result = ArrayList<String>()
        synchronized(mutex) {
            for ((name, _) in providers) {
                result.add(name)
            }
        }
        sort(result)
        result
    }

    /** 按配置创建实例；平台未实现时抛 `ChannelException` */
    public static func create(conf: ChannelAccountConf): Channel {
        let name = normalize(conf.platform)
        var factory: ?(ChannelAccountConf) -> Channel = None
        synchronized(mutex) {
            factory = providers.get(name)
        }
        match (factory) {
            case Some(make) => make(conf)
            case None => throw ChannelException('channel platform not supported: ${conf.platform}')
        }
    }

    /** 登记一个账号实例；同 `(platform, account)` 重复登记按最新一次覆盖 */
    public static func register(channel: Channel): Unit {
        let key = keyOf(channel.platform, channel.account)
        synchronized(mutex) {
            instances[key] = channel
        }
    }

    /** 已注册实例的平台（去重，排序） */
    public static func platforms(): ArrayList<String> {
        let result = ArrayList<String>()
        synchronized(mutex) {
            for ((_, channel) in instances) {
                let name = normalize(channel.platform)
                if (!result.contains(name)) {
                    result.add(name)
                }
            }
        }
        sort(result)
        result
    }

    /** 某平台下的账号名（排序） */
    public static func accounts(platform: String): ArrayList<String> {
        let name = normalize(platform)
        let result = ArrayList<String>()
        synchronized(mutex) {
            for ((_, channel) in instances) {
                if (normalize(channel.platform) == name) {
                    result.add(channel.account)
                }
            }
        }
        sort(result)
        result
    }

    /**
     * 取通道实例。
     *
     * @throws ChannelException 平台/账号不存在，或账号留空但该平台有多个账号
     */
    public static func channel(platform: String, account: String): Channel {
        let name = normalize(platform)
        let wanted = normalize(account)
        var found: ?Channel = None
        var matches = ArrayList<Channel>()
        synchronized(mutex) {
            if (!wanted.isEmpty()) {
                found = instances.get(keyOf(name, wanted))
            } else {
                for ((_, channel) in instances) {
                    if (normalize(channel.platform) == name) {
                        matches.add(channel)
                    }
                }
            }
        }
        match (found) {
            case Some(value) => return value
            case None => ()
        }
        if (!wanted.isEmpty()) {
            var known = false
            synchronized(mutex) {
                known = providers.contains(name)
            }
            if (!known) {
                throw ChannelException('channel platform not supported: ${platform}')
            }
            throw ChannelException('channel not found: ${platform}/${account}')
        }
        if (matches.size == 1) {
            return matches[0]
        }
        if (matches.isEmpty()) {
            // 平台压根没实现（只有预留常量）时给「不支持」，与「有实现但没配账号」区分开
            var known = false
            synchronized(mutex) {
                known = providers.contains(name)
            }
            if (!known) {
                throw ChannelException('channel platform not supported: ${platform}')
            }
            throw ChannelException('channel not found: ${platform} (no account registered)')
        }
        throw ChannelException('channel account is required: ${platform} has ${matches.size} accounts')
    }

    public static func send(platform: String, account: String, message: OutboundMessage): SendReceipt {
        channel(platform, account).send(message)
    }

    public static func receive(platform: String, account: String, limit: Int64, downloadDir!: String = ''): ArrayList<InboundMessage> {
        channel(platform, account).receive(limit, downloadDir)
    }

    /** 清空实例、保留 provider（重装配 / 测试用）——静态注册不能被清掉 */
    public static func reset(): Unit {
        synchronized(mutex) {
            instances.clear()
        }
    }

    /** 连 provider 一起清空：只给「验证注册表本身」的用例用 */
    public static func resetAll(): Unit {
        synchronized(mutex) {
            instances.clear()
            providers.clear()
        }
    }
}
