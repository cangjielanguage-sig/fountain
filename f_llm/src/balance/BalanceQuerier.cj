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
package fountain::f_llm.balance

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex

import fountain::f_bean.*
import fountain::f_data.macros.*
import fountain::f_log.*

import fountain::f_llm.config.*
import fountain::f_llm.model.po.*

/**
 * 一次余额查询的结果。多币种平台**每个币种一条**，不取下标 0 覆盖。
 *
 * 金额同时保留原始字符串（`total` 等，定点不失真）与 `Float64` 视图（只用于阈值比较）。
 */
@DataAssist[props fields]
public class BalanceSnapshot {
    public BalanceSnapshot(
        private var provider!: String = '',
        private var currency!: String = '',
        private var total!: String = '',
        private var granted!: String = '',
        private var toppedUp!: String = '',
        private var available!: Bool = true,
        private var low!: Bool = false,
        private var totalValue!: Float64 = 0.0f64,
        /** 账号标识（腾讯云 Uin / 火山 AccountID；DeepSeek 不提供则为空） */
        private var account!: String = '',
        /** 信用额度（元） */
        private var creditLimit!: String = '',
        /** 冻结金额（元） */
        private var frozen!: String = '',
        /** 查询时间（ISO 8601） */
        private var queriedAt!: String = '',
        /** 该平台的原始响应，排障用 */
        private var raw!: String = ''
    ){}
}

/** 平台没有可用的余额查询实现 */
public class BalanceUnsupportedException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 余额查询能力。
 *
 * 约定：查不到就是**抛异常**，不得返回 0 或空快照——余额为 0 与「查不到」是两件事，
 * 混在一起会让告警与预算逻辑全部失真。
 */
public interface BalanceQuerier {
    prop provider: String
    func query(conf: LLMConf): ArrayList<BalanceSnapshot>
}

/** 注册表 + 中介者：`@Bean` 自动发现与显式注册两条路，同名注册直接失败 */
public class BalanceMediator {
    public static let instance = BalanceMediator()

    private static let log = LoggerFactory.getLogger<BalanceMediator>()

    private let mutex = Mutex()
    private let queriers = HashMap<String, BalanceQuerier>()
    private var loaded = false

    private init(){}

    public func register(querier: BalanceQuerier): Unit {
        ensureLoaded()
        synchronized(mutex){
            if(queriers.contains(querier.provider)){
                throw IllegalArgumentException('balance querier already registered: ${querier.provider}')
            }
            queriers[querier.provider] = querier
        }
    }

    public func names(): ArrayList<String> {
        ensureLoaded()
        let result = ArrayList<String>()
        for((name, _) in queriers){
            result.add(name)
        }
        result
    }

    public func query(provider: String, conf: LLMConf): ArrayList<BalanceSnapshot> {
        ensureLoaded()
        let querier = synchronized(mutex){
            queriers.get(provider)
        }
        if(let Some(found) <- querier){
            return mark(found.query(conf), provider)
        }
        throw BalanceUnsupportedException('balance query is not supported for provider: ${provider}, available: ${names()}')
    }

    /** 按配置里出现过的平台各查一次；单个平台失败不影响其他平台 */
    public func queryAll(confs: ArrayList<LLMConf>): ArrayList<BalanceSnapshot> {
        let result = ArrayList<BalanceSnapshot>()
        let seen = HashMap<String, Bool>()
        for(conf in confs){
            if(seen.contains(conf.provider)){
                continue
            }
            seen[conf.provider] = true
            try{
                result.add(all: query(conf.provider, conf))
            }catch(e: Exception){
                log.warn(e){'balance query failed, provider: ${conf.provider}'}
            }
        }
        result
    }

    private func mark(snapshots: ArrayList<BalanceSnapshot>, provider: String): ArrayList<BalanceSnapshot> {
        let threshold = Float64(LLMConfig.getBalanceLowThreshold())
        for(snapshot in snapshots){
            snapshot.provider = provider
            if(!snapshot.available || snapshot.totalValue < threshold){
                snapshot.low = true
                log.warn{'low balance, provider: ${provider}, currency: ${snapshot.currency}, total: ${snapshot.total}'}
            }
        }
        snapshots
    }

    private func ensureLoaded(){
        synchronized(mutex){
            if(loaded){
                return
            }
            try{
                for(querier in lookupList<BalanceQuerier>()){
                    queriers[querier.provider] = querier
                }
            }catch(e: Exception){
                log.warn(e){'balance querier scan failed'}
            }
            loaded = true
        }
    }
}

func LLMConfig_balanceLowThreshold(): Float64 {
    Float64(LLMConfig.getBalanceLowThreshold())
}
