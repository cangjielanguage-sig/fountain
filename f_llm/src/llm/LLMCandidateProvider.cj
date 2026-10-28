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

import std.collection.ArrayList
import std.sync.Mutex

import fountain::f_bean.*

import fountain::f_llm.model.po.*

/**
 * 当前可用配置的来源。
 *
 * 工具（搜索/抓取）只需要「随便一条可用配置的凭据」，不关心它来自数据库还是文件；
 * 这里把「怎么取配置」抽成一个可替换的函数，测试注入即可，工具本身不碰 DB。
 */
public class LLMCandidateProvider {
    private static let mutex = Mutex()
    private static var supplier: () -> ArrayList<LLMConf> = defaultSupplier

    private init(){}

    private static func defaultSupplier(): ArrayList<LLMConf> {
        // 新配置快照已经按 enabled/weight>0 过滤并丢弃残缺行，不再走旧的 LLMFinder
        try{
            LLMConfs.holder().all()
        }catch(_: Exception){
            ArrayList<LLMConf>()
        }
    }

    public static func setSupplier(value: () -> ArrayList<LLMConf>): Unit {
        synchronized(mutex){
            supplier = value
        }
    }

    public static func candidates(): ArrayList<LLMConf> {
        let current = synchronized(mutex){
            supplier
        }
        current()
    }
}
