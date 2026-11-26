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
package fountain::f_llm.service

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_orm.*

import fountain::f_llm.dao.*
import fountain::f_llm.model.po.*

/**
 * llm_conf 的唯一读取入口：任何从数据库取配置的代码都依赖本接口，
 * 通过 `lookup<LLMConfService>()` 取实例，不直接碰 DAO 或 SqlExecutor。
 */
public interface LLMConfService <: RootService {
    /** 装载用：只取启用且权重大于 0 的配置 */
    func listEnabled(): ArrayList<LLMConf>

    func findById(id: Int64): ?LLMConf

    /** 返回自增主键 */
    func save(conf: LLMConf): Int64

    func update(conf: LLMConf): Int64

    func clear(): Int64
}

@Bean
public class LLMConfServiceImpl <: LLMConfService {
    public func listEnabled(): ArrayList<LLMConf> {
        executor().listEnabled()
    }

    public func findById(id: Int64): ?LLMConf {
        executor().findById(id)
    }

    public func save(conf: LLMConf): Int64 {
        executor().insertConf(conf)
    }

    public func update(conf: LLMConf): Int64 {
        executor().updateById(conf)
    }

    public func clear(): Int64 {
        executor().deleteAll()
    }
}
