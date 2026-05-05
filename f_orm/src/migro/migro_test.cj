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
package fountain::f_orm.migro

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList

/**
 * Unit tests for DDL generation methods in SchemaFinder implementations.
 * These tests verify SQL output without requiring a database connection.
 */
@Test
public class MigroDDLTest {
    private func collect(itr: Iterator<String>): ArrayList<String> {
        let list = ArrayList<String>()
        for (s in itr) { list.add(s) }
        list
    }

    private func col(name: String, type: String, nullable: Bool, extra: String = "", dflt: ?String = None, oldName: String = ""): ColumnMeta {
        let m = ColumnMeta()
        m.columnName = name
        m.oldColumnName = oldName
        m.typeName = type
        m.nullable = nullable
        m.extra = extra
        m.default = dflt
        m
    }

    private func idx(name: String, columns: String, unique: Bool, def: String = ""): IndexMeta {
        let m = IndexMeta(name, columns, unique)
        m.def = def
        m
    }

    // MySQL CREATE TABLE
    @TestCase
    public func testMysqlCreateTable(): Unit {
        let finder = MysqlSchemaFinder()
        let cols = ArrayList<ColumnMeta>()
        cols.add(col("id", "bigint", false, "auto_increment"))
        cols.add(col("name", "varchar(100)", true))
        let sqls = collect(finder.generateCreateSql("users", cols.iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("create table users"))
        @Assert(true, sqls[0].contains("id bigint not null auto_increment"))
        @Assert(true, sqls[0].contains("name varchar(100)"))
    }

    // MySQL DROP TABLE
    @TestCase
    public func testMysqlDropTable(): Unit {
        let finder = MysqlSchemaFinder()
        @Assert("drop table users;", finder.generateDropTableSql("users"))
    }

    // MySQL ALTER ADD COLUMN
    @TestCase
    public func testMysqlAlterAddColumn(): Unit {
        let finder = MysqlSchemaFinder()
        let newCols = [col("email", "varchar(255)", true)]
        let sqls = collect(finder.generateAlterSql("users", newCols, ArrayList<ColumnMeta>().iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("add column email varchar(255)"))
    }

    // MySQL ALTER DROP COLUMN
    @TestCase
    public func testMysqlAlterDropColumn(): Unit {
        let finder = MysqlSchemaFinder()
        let currentCols = [col("obsolete", "int", true)]
        let sqls = collect(finder.generateAlterSql("users", ArrayList<ColumnMeta>().toArray(), currentCols.iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("drop column obsolete"))
    }

    // MySQL ALTER CHANGE COLUMN (rename + type)
    @TestCase
    public func testMysqlAlterChangeColumn(): Unit {
        let finder = MysqlSchemaFinder()
        let newCols = [col("email_addr", "varchar(200)", false, "", None, "email")]
        let currentCols = [col("email", "varchar(100)", true, "", Some("''"))]
        let sqls = collect(finder.generateAlterSql("users", newCols, currentCols.iterator()))
        @Assert(true, sqls.size > 0)
        @Assert(true, sqls[0].contains("change email email_addr"))
        @Assert(true, sqls[0].contains("varchar(200)"))
        @Assert(true, sqls[0].contains("not null"))
    }

    // MySQL ADD INDEX
    @TestCase
    public func testMysqlAddIndex(): Unit {
        let finder = MysqlSchemaFinder()
        let sqls = collect(finder.generateIndexSql("users", [idx("idx_name", "name", false)], ArrayList<IndexMeta>().iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("add index idx_name (name)"))
    }

    // MySQL ADD UNIQUE INDEX
    @TestCase
    public func testMysqlAddUniqueIndex(): Unit {
        let finder = MysqlSchemaFinder()
        let sqls = collect(finder.generateIndexSql("users", [idx("uk_email", "email", true)], ArrayList<IndexMeta>().iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("add unique uk_email (email)"))
    }

    // MySQL DROP INDEX
    @TestCase
    public func testMysqlDropIndex(): Unit {
        let finder = MysqlSchemaFinder()
        let currentIdx = [idx("old_idx", "obsolete", false)]
        let sqls = collect(finder.generateIndexSql("users", ArrayList<IndexMeta>().toArray(), currentIdx.iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("drop index old_idx"))
    }

    // Postgres CREATE TABLE with DEFAULT
    @TestCase
    public func testPostgresCreateTable(): Unit {
        let finder = PostgresSchemaFinder()
        let cols = ArrayList<ColumnMeta>()
        cols.add(col("id", "bigint", false))
        cols.add(col("name", "varchar(100)", true))
        cols.add(col("score", "int", false, "", Some("0")))
        let sqls = collect(finder.generateCreateSql("users", cols.iterator()))
        @Assert(2, sqls.size)
        @Assert(true, sqls[0].contains("create table users"))
        @Assert(true, sqls[0].contains("id bigint not null"))
        @Assert(true, sqls[1].contains("ALTER TABLE users ALTER score SET DEFAULT '0'"))
    }

    // Postgres ALTER RENAME COLUMN + TYPE + NOT NULL
    @TestCase
    public func testPostgresAlterRenameColumn(): Unit {
        let finder = PostgresSchemaFinder()
        let newCols = [col("full_name", "text", false, "", None, "name")]
        let currentCols = [col("name", "varchar(100)", true)]
        let sqls = collect(finder.generateAlterSql("users", newCols, currentCols.iterator()))
        @Assert(true, sqls.size >= 3)
        @Assert(true, sqls[0].contains("rename column name to full_name"))
        @Assert(true, sqls[1].contains("alter column full_name type text"))
        @Assert(true, sqls[sqls.size - 1].contains("alter column full_name set not null"))
    }

    // Postgres ALTER SET/DROP NOT NULL with column name
    @TestCase
    public func testPostgresAlterNotNull(): Unit {
        let finder = PostgresSchemaFinder()
        let newCols = [col("name", "varchar(100)", false)]
        let currentCols = [col("name", "varchar(100)", true)]
        let sqls = collect(finder.generateAlterSql("users", newCols, currentCols.iterator()))
        @Assert(true, sqls.size > 0)
        for (sql in sqls) {
            @Assert(true, sql.contains("alter column name"))
        }
    }

    // Postgres ALTER ADD COLUMN with default and not null
    @TestCase
    public func testPostgresAlterAddColumn(): Unit {
        let finder = PostgresSchemaFinder()
        let newCols = [col("email", "varchar(255)", false, "", Some("''"))]
        let sqls = collect(finder.generateAlterSql("users", newCols, ArrayList<ColumnMeta>().iterator()))
        @Assert(true, sqls.size >= 2)
        @Assert(true, sqls[0].contains("add column email varchar(255) not null"))
        @Assert(true, sqls[1].contains("alter column email set default"))
    }

    // Postgres INDEX via indexdef
    @TestCase
    public func testPostgresIndexDef(): Unit {
        let finder = PostgresSchemaFinder()
        let newIdx = idx("idx_name", "name", false, "CREATE INDEX idx_name ON users USING btree (name)")
        let sqls = collect(finder.generateIndexSql("users", [newIdx], ArrayList<IndexMeta>().iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains(newIdx.def))
    }

    // Postgres DROP INDEX uses correct syntax
    @TestCase
    public func testPostgresDropIndex(): Unit {
        let finder = PostgresSchemaFinder()
        let currentIdx = [idx("old_idx", "obsolete", false)]
        let sqls = collect(finder.generateIndexSql("users", ArrayList<IndexMeta>().toArray(), currentIdx.iterator()))
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].startsWith("drop index"))
    }

    // MariaDB driverName is 'mariadb' not 'mysql'
    @TestCase
    public func testMariaDBDriverName(): Unit {
        let finder = MariaDBSchemaFinder()
        @Assert("mariadb", finder.driverName)
    }
}
