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
package fountain::f_dbd.multid

import std.collection.ArrayList
import std.convert.*
import std.unicode.UnicodeStringExtension
import fountain::f_config.Config

/**
 * 多节点驱动的配置（设计 §6.1）：全部经 `f_config.Config` 读取，未配置或非法时取默认值。
 *
 * 时间项的单位按需求原文：`IdleTimeout` / `ConnectionLife` / `CheckInterval` 为**秒**，
 * `ConnectTimeout` / `MaxWaiting` 为**毫秒**；`MaxWaiting == 0` 表示真无限等待。
 */
protected struct MultiDConfig {
    static const LOAD_BALANCE: String = 'multidbm_loadbalance'
    static const INIT_SIZE: String = 'multidbm_databasePoolInitSize'
    static const MIN_SIZE: String = 'multidbm_databasePoolMinSize'
    static const MAX_SIZE: String = 'multidbm_databasePoolMaxSize'
    static const CHECK_ON_CREATION: String = 'multidbm_databasePoolCheckOnCreation'
    static const CHECK_ON_BORROWING: String = 'multidbm_databasePoolCheckOnBorrowing'
    static const CHECK_ON_RETURNING: String = 'multidbm_databasePoolCheckOnReturning'
    static const IDLE_TIMEOUT: String = 'multidbm_databasePoolIdleTimeout'
    static const CONNECTION_LIFE: String = 'multidbm_databasePoolConnectionLife'
    static const CHECK_INTERVAL: String = 'multidbm_databasePoolCheckInterval'
    static const CONNECT_TIMEOUT: String = 'multidbm_databasePoolConnectTimeout'
    static const MAX_WAITING: String = 'multidbm_databasePoolMaxWaiting'
    static const CHECK_SQL: String = 'multidbm_databasePoolCheckSql'

    /**
     * 负载均衡算法名（`random` / `roundrobin`）。
     *
     * `multidbm_loadbalance` 的首段是纯数字时视为权重列表，算法取默认 `random`；
     * 空串 / 缺省同为 `random`。
     */
    public static func getLoadBalance(): String {
        let segments = segmentsOf(Config.getString(LOAD_BALANCE) ?? '')
        if (segments.isEmpty()) {
            return 'random'
        }
        let first = segments[0]
        if (Int64.tryParse(first).isSome()) {
            return 'random'
        }
        if (first.isEmpty()) {
            'random'
        } else {
            first
        }
    }

    /**
     * 权重列表：`'random,1,2,3'` / `'roundrobin,1,2,3'` / `'1,2,3'` 都得到 `[1,2,3]`；
     * 不含权重时返回空数组（调用方按等权处理）。非数字段被忽略。
     */
    public static func getWeights(): Array<Int64> {
        let segments = segmentsOf(Config.getString(LOAD_BALANCE) ?? '')
        let weights = ArrayList<Int64>()
        for (i in 0..segments.size) {
            if (i == 0 && Int64.tryParse(segments[i]).isNone()) {
                continue
            }
            match (Int64.tryParse(segments[i])) {
                case Some(value) => weights.add(value)
                case None => ()
            }
        }
        weights.toArray()
    }

    public static func getInitSize(): Int64 {
        intOf(INIT_SIZE, 1)
    }

    public static func getMinSize(): Int64 {
        intOf(MIN_SIZE, 1)
    }

    public static func getMaxSize(): Int64 {
        intOf(MAX_SIZE, 1)
    }

    public static func getCheckOnCreation(): Bool {
        boolOf(CHECK_ON_CREATION, false)
    }

    public static func getCheckOnBorrowing(): Bool {
        boolOf(CHECK_ON_BORROWING, true)
    }

    public static func getCheckOnReturning(): Bool {
        boolOf(CHECK_ON_RETURNING, false)
    }

    /** 连接闲置时间；`0` 表示不过期。 */
    public static func getIdleTimeout(): Duration {
        Duration.second * intOf(IDLE_TIMEOUT, 0)
    }

    public static func getConnectionLife(): Duration {
        Duration.second * intOf(CONNECTION_LIFE, 86400)
    }

    public static func getCheckInterval(): Duration {
        Duration.second * intOf(CHECK_INTERVAL, 300)
    }

    public static func getConnectTimeout(): Duration {
        Duration.millisecond * intOf(CONNECT_TIMEOUT, 50)
    }

    /** 池耗尽的等待上限；`0` → `Duration.Max`（真无限等待）。 */
    public static func getMaxWaiting(): Duration {
        let ms = intOf(MAX_WAITING, 30000)
        if (ms <= 0) {
            Duration.Max
        } else {
            Duration.millisecond * ms
        }
    }

    public static func getCheckSql(): String {
        let sql = Config.getString(CHECK_SQL) ?? 'select 1'
        if (sql.isEmpty()) {
            'select 1'
        } else {
            sql
        }
    }

    private static func intOf(key: String, fallback: Int64): Int64 {
        match (Config.getValue<Int64>(key)) {
            case Some(value) => value
            case None => fallback
        }
    }

    private static func boolOf(key: String, fallback: Bool): Bool {
        match (Config.getString(key)) {
            case Some(value) =>
                let text = value.trimAscii().toLower()
                if (text == 'true' || text == '1') {
                    true
                } else if (text == 'false' || text == '0') {
                    false
                } else {
                    fallback
                }
            case None => fallback
        }
    }

    /** 逗号分段并去掉首尾空白（去掉空段）。 */
    private static func segmentsOf(raw: String): Array<String> {
        let result = ArrayList<String>()
        for (part in raw.split(',')) {
            let text = part.trimAscii()
            if (!text.isEmpty()) {
                result.add(text)
            }
        }
        result.toArray()
    }
}
