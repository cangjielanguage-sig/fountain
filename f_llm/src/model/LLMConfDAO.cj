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
package fountain::f_llm.model

import std.collection.HashSet

import fountain::f_orm.*
import fountain::f_orm.macros.*

import fountain::f_llm.model.po.*

/**
 * llm_conf 的数据库访问。
 *
 * 用 f_orm 的 @DAO：SQL 由 f_orm 按当前驱动生成，应用侧不写方言 SQL。
 *
 * 每个方法都用 `ORM.executor()` 取当前线程的执行器，而不是复用调用方传进来的实例：
 * 一次语句执行结束（尤其自动提交）后，f_orm 会清空线程内的 current 执行器，
 * 复用旧实例会在拼列名时抛 NoneValueException。
 */
@DAO
public interface LLMConfDAO <: RootDAO {
    /** 装载用：只取启用且权重大于 0 的配置（`enabled = true` 在 PG / MySQL 上都成立） */
    func listEnabled(): ArrayList<LLMConf> {
        ORM.executor().setSql('SELECT * FROM llm_conf WHERE enabled = true AND weight > 0').list<LLMConf>()
    }

    func findById(id: Int64): Option<LLMConf> {
        ORM.executor().setSql('SELECT * FROM llm_conf WHERE id = ${id}').first<LLMConf>()
    }

    /** 返回自增主键（方法名不能叫 insert：SqlExecutor 已有同名属性）；id 交给数据库生成 */
    func insertConf(conf: LLMConf): Int64 {
        ORM.executor().INSERT_INTO<LLMConf>(conf, ignoreColumns: [LLMConf.tableColumns().id])
    }

    /** 以主键为 WHERE 条件整行更新 */
    func updateById(conf: LLMConf): Int64 {
        ORM.executor().UPDATE<LLMConf>(
            conf,
            ignoredColumns: HashSet<String>(),
            includingColumns: HashSet<String>(),
            dirty: false
        )
    }

    func deleteAll(): Int64 {
        ORM.executor().setSql('DELETE FROM llm_conf').delete
    }
}
