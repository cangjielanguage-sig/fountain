/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_orm.wrap

/**
 * `DatabasePool` / `PooledConnection` 已迁到 `fountain::f_dbpool`（`f_dbpool` 模块只依赖 `f_pool`），
 * 这里只做重导出，保持 `fountain::f_orm.wrap.DatabasePool` 这一写法可用。
 *
 * 迁移带来的两处构造器变化（见 `f_dbpool/src/DatabasePool.cj`）：
 * - `init(driver: Driver, ds: Datasource)`（参数取自 `ORMConfig`）已删除，`orm_*` 的池参数由调用方
 *   自己读（本模块 `NamedDatasource` 就是这么做的）；
 * - `init(driver: Driver, options!)` 改为 `init(driver: Driver, url: String, options!)`，
 *   连接串不再从 `ORMConfig.getUrl` 取。
 * 抛出的 `ConnectionException` / `ORMException` 也是 `fountain::f_dbpool` 里的那一份，
 * 与 `fountain::f_orm.exception` 下的同名类型不是同一个声明。
 */
public import fountain::f_dbpool.DatabasePool
