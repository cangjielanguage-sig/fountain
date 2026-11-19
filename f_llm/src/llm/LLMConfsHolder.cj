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
package fountain::f_llm.llm

import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.Mutex
import std.time.MonoTime

import fountain::f_concurrent.*
import fountain::f_log.*

import fountain::f_llm.config.*
import fountain::f_llm.model.po.*
import fountain::f_llm.service.*

/** 一份不可变配置快照：刷新时整体替换，读路径无锁 */
public class LLMConfsSnapshot {
    public let version: Int64
    public let byId: HashMap<Int64, LLMConf>
    public let byName: HashMap<String, ArrayList<LLMConf>>
    public let loadedAt: MonoTime

    public init(
        version: Int64,
        byId: HashMap<Int64, LLMConf>,
        byName: HashMap<String, ArrayList<LLMConf>>,
        loadedAt: MonoTime
    ){
        this.version = version
        this.byId = byId
        this.byName = byName
        this.loadedAt = loadedAt
    }

    /** 候选列表：`weight <= 0` 与停用等价，任何来源（库/文件/环境变量）都不得进入候选 */
    public func candidates(llmName: String): ArrayList<LLMConf> {
        let list = ArrayList<LLMConf>()
        for(conf in byName.get(llmName) ?? ArrayList<LLMConf>()){
            if(conf.weight > 0){
                list.add(conf)
            }
        }
        list
    }

    public func all(): ArrayList<LLMConf> {
        let list = ArrayList<LLMConf>()
        for((_, conf) in byId){
            if(conf.weight > 0){
                list.add(conf)
            }
        }
        list
    }
}

/**
 * 配置装载与刷新。
 *
 * - 首次访问装载一次，之后按周期（`llm_confRefreshSeconds`，默认 60s）刷新；
 * - 不起线程、不起定时器：周期内第一次访问触发（懒式 TTL）；
 * - 刷新整体替换快照，在途请求继续用旧快照；刷新失败保留旧快照并记 error。
 */
public class LLMConfsHolder {
    private static let log = LoggerFactory.getLogger<LLMConfsHolder>()

    private let mutex = Mutex()
    private var refreshing = false
    private var snapshot: LLMConfsSnapshot
    private let source: LLMConfSource
    private let refreshInterval: Duration
    private let breaker: CircuitBreaker
    private let algorithm: String
    private let balancerMutex = Mutex()
    private let balancers = HashMap<String, LoadBalance<Int64, Unit, LLMConf>>()
    private var balancersVersion: Int64 = -1

    public init(
        source!: LLMConfSource,
        refreshInterval!: Duration = LLMConfig.getConfRefreshInterval(),
        breaker!: CircuitBreaker = CircuitBreaker(),
        algorithm!: String = LLMConfig.getLoadBalanceAlgo()
    ){
        this.source = source
        this.refreshInterval = refreshInterval
        this.breaker = breaker
        this.algorithm = algorithm
        snapshot = LLMConfsSnapshot(0, HashMap<Int64, LLMConf>(), HashMap<String, ArrayList<LLMConf>>(), MonoTime.now())
    }

    public prop version: Int64 {
        get() {
            snapshot.version
        }
    }

    /** 每次访问入口调用；未到周期时零开销 */
    public func ensureFresh(): Unit {
        let current = snapshot
        if(current.version > 0 && MonoTime.now() - current.loadedAt < refreshInterval){
            return
        }
        refresh(current)
    }

    /** 运维/测试用：强制刷新 */
    public func refreshNow(): Unit {
        refresh(snapshot)
    }

    public func candidates(llmName: String): ArrayList<LLMConf> {
        ensureFresh()
        snapshot.candidates(llmName)
    }

    public func all(): ArrayList<LLMConf> {
        ensureFresh()
        snapshot.all()
    }

    /** 该 conf 的上下文阈值；0 表示不限制 */
    public func getTokenThreshold(conf: LLMConf): Int64 {
        conf.tokenThreshold
    }

    /** 上下文是否已达该 conf 的阈值（0 表示永不溢出） */
    public func saturated(conf: LLMConf, messages: ArrayList<ChatMessage>): Bool {
        let threshold = conf.tokenThreshold
        if(threshold <= 0){
            return false
        }
        HeuristicTokenCounter().count(conf, messages) >= threshold
    }

    /** 熔断状态查询（编排层用来决定是否跳过） */
    public func isCircuitOpen(confId: Int64): Bool {
        breaker.isOpen(confId)
    }

    public func recordSuccess(confId: Int64): Unit {
        breaker.recordSuccess(confId)
    }

    /** 只对可重试失败调用（连接失败/超时/429/5xx/流中断） */
    public func recordRetryableFailure(confId: Int64): Unit {
        breaker.recordRetryableFailure(confId)
    }

    /**
     * 按权重选出"下一次会用到"的 conf；跳过已熔断的。
     *
     * 调度器按 llmName 缓存、随快照版本重建（轮询算法靠实例内的游标，不能每次都新建）；
     * 用 iterator() 而不是 call(maxRetrying)：后者会把 4xx 也当故障转移。
     */
    public func peekNext(llmName: String): ?LLMConf {
        ensureFresh()
        if(let Some(balancer) <- balancerFor(llmName)){
            let count = snapshot.candidates(llmName).size
            let it = balancer.iterator()
            var i = 0
            while(i < count){
                i++
                match(it.next()){
                    case Some(pick) =>
                        let conf = pick(())
                        if(!breaker.isOpen(conf.id)){
                            return Some(conf)
                        }
                    case None => break
                }
            }
        }
        None<LLMConf>
    }

    private func balancerFor(llmName: String): ?LoadBalance<Int64, Unit, LLMConf> {
        synchronized(balancerMutex){
            if(balancersVersion != snapshot.version){
                balancers.clear()
                balancersVersion = snapshot.version
            }
            if(let Some(exist) <- balancers.get(llmName)){
                return Some(exist)
            }
            let usable = ArrayList<LLMConf>()
            var total = 0
            for(conf in snapshot.candidates(llmName)){
                if(conf.weight > 0){
                    usable.add(conf)
                    total += conf.weight
                }
            }
            if(usable.isEmpty()){
                return None<LoadBalance<Int64, Unit, LLMConf>>
            }
            // 键是累加权重（3、4…），取值区间 [1, total]：每个权重正好占到自己那份槽位
            let algo: LoadBalanceAlgo<Int64> = match(algorithm){
                case 'roundRobin' => RoundRobin<Int64>(1, 1, total)
                case _ => Int64Weight(1, total)
            }
            let balancer = LoadBalance<Int64, Unit, LLMConf>(0, algo)
            for(conf in usable){
                let chosen = conf
                balancer.add(chosen.weight){_ => chosen}
            }
            balancers[llmName] = balancer
            Some(balancer)
        }
    }

    private func refresh(old: LLMConfsSnapshot): Unit {
        synchronized(mutex){
            if(refreshing){
                return                      // 单飞：已有线程在刷，本次用旧快照
            }
            refreshing = true
        }
        try{
            let start = MonoTime.now()
            let confs = source.load()
            let byId = HashMap<Int64, LLMConf>()
            let byName = HashMap<String, ArrayList<LLMConf>>()
            var dropped = 0
            for(conf in confs){
                if(conf.isPlaceholder){
                    dropped++
                    continue
                }
                byId[conf.id] = conf
                if(let Some(list) <- byName.get(conf.llmName)){
                    list.add(conf)
                }else{
                    let list = ArrayList<LLMConf>()
                    list.add(conf)
                    byName[conf.llmName] = list
                }
            }
            if(dropped > 0){
                let droppedCount = dropped
                log.warn{'llm conf: ${droppedCount} record(s) dropped, provider/actualLlmName/url empty'}
            }
            snapshot = LLMConfsSnapshot(old.version + 1, byId, byName, MonoTime.now())
            // 已删除的配置不再需要熔断状态，顺手清理，避免内存缓慢增长
            breaker.cleanup(HashSet<Int64>(byId.keys()))
            log.info{'llm conf refreshed, version: ${snapshot.version}, confs: ${byId.size}, source: ${source.name}, elapsed: ${MonoTime.now() - start}'}
        }catch(e: Exception){
            log.error(e){'llm conf refresh failed, keep version ${old.version}, source: ${source.name}'}
        }finally{
            synchronized(mutex){
                refreshing = false
            }
        }
    }
}
