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
package fountain::f_llm.dao

import std.collection.HashSet

import fountain::f_orm.*
import fountain::f_orm.macros.*

import fountain::f_llm.model.po.*

/**
 * llm_conf 的数据库访问。
 *
 * 只用 RootDAO 的 `executor` 属性（当前线程的执行器）；对外由 LLMConfService 暴露，
 * 业务代码不直接依赖本接口。
 */
@DAO
public interface LLMConfDAO <: RootDAO {
    /** 装载用：只取启用且权重大于 0 的配置（`enabled = true` 在 PG / MySQL 上都成立） */
    func listEnabled(): ArrayList<LLMConf> {
        executor
            .setSql('SELECT * FROM llm_conf WHERE enabled = true AND weight > 0')
            .list<LLMConf>()
    }

    func findById(id: Int64): Option<LLMConf> {
        executor
            .setSql('SELECT * FROM llm_conf WHERE id = ${arg(id)}')
            .first<LLMConf>()
    }

    /** 返回自增主键（方法名不能叫 insert：SqlExecutor 已有同名属性）；id 交给数据库生成 */
    func insertConf(conf: LLMConf): Int64 {
        executor.INSERT_INTO<LLMConf>(conf, ignoreColumns: [LLMConf.tableColumns().id])
    }

    /** 以主键为 WHERE 条件整行更新 */
    func updateById(conf: LLMConf): Int64 {
        executor.UPDATE<LLMConf>(
            conf,
            ignoredColumns: HashSet<String>(),
            includingColumns: HashSet<String>(),
            dirty: false
        )
    }

    func deleteAll(): Int64 {
        executor.setSql('DELETE FROM llm_conf').delete
    }
}
