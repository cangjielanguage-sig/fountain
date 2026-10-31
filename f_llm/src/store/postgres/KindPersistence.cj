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
package fountain::f_llm.store.postgres

import fountain::f_orm.*

import fountain::f_llm.dao.postgres.*
import fountain::f_llm.store.*

/** PostgreSQL 记忆种类持久化（P1）：`llm_memory_kind` 的补种入口。 */
public class PostgresKindPersistence <: KindPersistence & RootService {
    public init() {
    }

    public func has(kind: String): Bool {
        dao<PostgresKindDAO>('postgres').kindHas(kind).isSome()
    }

    public func insert(kind: String, predefined: Bool): Unit {
        dao<PostgresKindDAO>('postgres').kindInsert(kind, predefined, MemoryKinds.weightOf(kind))
    }
}
