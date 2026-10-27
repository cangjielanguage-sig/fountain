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

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import std.time.MonoTime

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

    public func candidates(llmName: String): ArrayList<LLMConf> {
        byName.get(llmName) ?? ArrayList<LLMConf>()
    }

    public func all(): ArrayList<LLMConf> {
        let list = ArrayList<LLMConf>()
        for((_, conf) in byId){
            list.add(conf)
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

    public init(
        source!: LLMConfSource,
        refreshInterval!: Duration = LLMConfig.getConfRefreshInterval()
    ){
        this.source = source
        this.refreshInterval = refreshInterval
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
