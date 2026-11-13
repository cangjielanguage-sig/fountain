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
package fountain::f_llm.search

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex

import fountain::f_bean.*
import fountain::f_data.macros.*

import fountain::f_llm.model.po.*

/** 统一的搜索结果条目（各平台字段归一后只保留这些） */
@DataAssist[props fields]
public class SearchResultItem {
    public SearchResultItem(
        private var title!: String = '',
        private var url!: String = '',
        private var summary!: String = '',
        private var date!: String = '',
        private var score!: Float64 = 0.0f64
    ){}
}

/** 抓取结果 */
@DataAssist[props fields]
public class FetchedPage {
    public FetchedPage(
        private var title!: String = '',
        private var content!: String = ''
    ){}
}

/**
 * 一个平台能提供哪些工具能力，由它自己声明。
 *
 * 约定：`search` / `fetch` 失败必须抛异常，不得返回空列表冒充「没有结果」——
 * 否则模型会把「搜索挂了」当成「查无此事」继续编。
 */
public interface SearchProvider {
    prop provider: String
    /** 搜索端点；可被 `conf['searchUrl']` 覆盖 */
    prop searchEndpoint: String
    /** 抓取端点；空串表示该平台不支持抓取 */
    prop fetchEndpoint: String
    func search(conf: LLMConf, query: String, count: Int64, needContent: Bool): ArrayList<SearchResultItem>
    func fetch(conf: LLMConf, url: String): FetchedPage
}

/** 没有任何可用配置能跑这个工具时抛出（框架能力缺失，不是业务失败） */
public class SearchUnavailableException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 搜索/抓取的 HTTP 层失败（含**拒绝重定向**）。
 *
 * 单独一个类型是为了让调用方能把「协议层拒绝」与「业务无数据」区分开：
 * 3xx 必须当成失败，不能跟随——跳转目标没有经过 `SsrfGuard` 校验。
 */
public class SearchHttpException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/** 搜索能力注册表：同名重复注册直接失败；`@Bean` 自动发现 + 显式注册两条路 */
public class SearchProviderRegistry {
    private static let mutex = Mutex()
    private static let providers = HashMap<String, SearchProvider>()
    private static var loaded = false

    private init(){}

    public static func register(provider: SearchProvider): Unit {
        ensureLoaded()
        synchronized(mutex){
            if(providers.contains(provider.provider)){
                throw IllegalArgumentException('search provider already registered: ${provider.provider}')
            }
            providers[provider.provider] = provider
        }
    }

    public static func get(provider: String): ?SearchProvider {
        ensureLoaded()
        synchronized(mutex){
            providers.get(provider)
        }
    }

    public static func names(): ArrayList<String> {
        ensureLoaded()
        synchronized(mutex){
            let result = ArrayList<String>()
            for((name, _) in providers){
                result.add(name)
            }
            result
        }
    }

    /** 扫描 @Bean；单个 provider 构造失败只跳过，不影响其他平台 */
    private static func ensureLoaded(): Unit {
        synchronized(mutex){
            if(loaded){
                return
            }
            try{
                for(provider in lookupList<SearchProvider>()){
                    providers[provider.provider] = provider
                }
            }catch(_: Exception){
                // 没有 bean 容器（或扫描失败）时退化为纯显式注册
            }
            loaded = true
        }
    }
}
