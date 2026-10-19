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
package fountain::fdbm.sql

import std.unicode.UnicodeStringExtension

/** 物理库方言族（设计 D2）：方言差异只在 fdbm 内处理，配置与协议不感知。 */
protected enum SqlDialect <: Equatable<SqlDialect> {
    | Postgres | MySql | Unknown

    public operator func ==(other: SqlDialect): Bool {
        index() == other.index()
    }

    func index(): Int64 {
        match (this) {
            case Postgres => 0
            case MySql => 1
            case Unknown => 2
        }
    }
}

/**
 * 驱动名 → 方言族 / 标识符引用（设计 D2、D3）。
 *
 * 驱动名是 fdbm 启动时的权威信息；一个进程内物理驱动唯一（启动校验），
 * 因此不需要按库混排方言。
 */
protected struct SqlDialects {

    /** 大小写不敏感的子串匹配；`MariaDB` 按 MySQL、`openGauss` 按 PostgreSQL。 */
    public static func ofDriver(driverName: String): SqlDialect {
        let name = driverName.toLower()
        if (name.contains('postgres') || name.contains('pgsql') || name.contains('opengauss')) {
            return SqlDialect.Postgres
        }
        if (name.contains('mysql') || name.contains('mariadb')) {
            return SqlDialect.MySql
        }
        SqlDialect.Unknown
    }

    /** 按方言族加引用符；未知方言按 SQL 标准用双引号（与 PostgreSQL 一致）。 */
    public static func quoteIdentifier(name: String, dialect: SqlDialect): String {
        match (dialect) {
            case MySql => '`${name.replace('`', '``')}`'
            case _ => '"${name.replace('"', '""')}"'
        }
    }
}
