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
import fountain::f_data.*
import fountain::f_data.base.*

/**
 * Tests that verify the PO → ColumnMeta mapping layer used by SchemaFinder.
 * These tests validate that information_schema query results map correctly
 * to ColumnMeta objects used by DDL generation, using DataDict + DataObject.populate.
 */
@Test
public class MockMigroPOTest {
    private func buildData(entries: Array<(String, Data)>): DataDict {
        let d = DataDict()
        for((k, v) in entries){
            d.add(k, v)
        }
        d
    }

    /**
     * Test MySQL column PO → ColumnMeta mapping.
     * DataDict keys must match ColumnMeta property names (columnName, not column_name).
     */
    @TestCase
    public func testMysqlPOToColumnMeta(): Unit {
        let poData = buildData([
            ('columnName', DataString('id')),
            ('typeName', DataString('bigint')),
            ('nullable', DataBool.FALSE),
            ('extra', DataString('auto_increment')),
            ('default', DataNone.INSTANCE)
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(poData)) {
            @Assert('id', cm.columnName)
            @Assert('bigint', cm.typeName)
            @Assert(false, cm.nullable)
            @Assert('auto_increment', cm.extra)
            @Assert(true, cm.default.isNone())
        } else {
            @Assert(false)
        }
    }

    /**
     * Test nullable=true mapping.
     */
    @TestCase
    public func testMysqlNullableTrue(): Unit {
        let poData = buildData([
            ('columnName', DataString('name')),
            ('typeName', DataString('varchar(100)')),
            ('nullable', DataBool.TRUE),
            ('extra', DataString(''))
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(poData)) {
            @Assert('name', cm.columnName)
            @Assert('varchar(100)', cm.typeName)
            @Assert(true, cm.nullable)
        } else {
            @Assert(false)
        }
    }

    /**
     * Test default value mapping.
     */
    @TestCase
    public func testMysqlDefaultValue(): Unit {
        let poData = buildData([
            ('columnName', DataString('score')),
            ('typeName', DataString('int')),
            ('nullable', DataBool.FALSE),
            ('default', DataString('0')),
            ('extra', DataString(''))
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(poData)) {
            @Assert('score', cm.columnName)
            @Assert(false, cm.nullable)
            if (let Some(d) <- cm.default) {
                @Assert('0', d)
            } else {
                @Assert(false)
            }
        } else {
            @Assert(false)
        }
    }

    /**
     * Test Postgres PO → ColumnMeta mapping.
     */
    @TestCase
    public func testPostgresPOToColumnMeta(): Unit {
        let poData = buildData([
            ('columnName', DataString('id')),
            ('typeName', DataString('bigint')),
            ('nullable', DataBool.FALSE)
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(poData)) {
            @Assert('id', cm.columnName)
            @Assert('bigint', cm.typeName)
            @Assert(false, cm.nullable)
        } else {
            @Assert(false)
        }
    }

    /**
     * Test Postgres VARCHAR with type length mapping.
     */
    @TestCase
    public func testPostgresPOWithTypeLength(): Unit {
        let poData = buildData([
            ('columnName', DataString('name')),
            ('typeName', DataString('varchar(100)')),
            ('nullable', DataBool.TRUE)
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(poData)) {
            @Assert('name', cm.columnName)
            @Assert('varchar(100)', cm.typeName)
            @Assert(true, cm.nullable)
        } else {
            @Assert(false)
        }
    }

    /**
     * Test that ColumnMeta from DataDict → DDL generation works end-to-end.
     * Simulates what the SchemaFinder does: query → map → generate DDL.
     */
    @TestCase
    public func testCreateTableFromDataDict(): Unit {
        let cols = ArrayList<ColumnMeta>()

        // Build ColumnMeta for 'id bigint NOT NULL auto_increment'
        let idData = buildData([
            ('columnName', DataString('id')),
            ('typeName', DataString('bigint')),
            ('nullable', DataBool.FALSE),
            ('extra', DataString('auto_increment'))
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(idData)) {
            cols.add(cm)
        }

        // Build ColumnMeta for 'name varchar(100)'
        let nameData = buildData([
            ('columnName', DataString('name')),
            ('typeName', DataString('varchar(100)')),
            ('nullable', DataBool.FALSE)
        ])
        if (let Some(cm) <- DataObject<ColumnMeta>.populate(nameData)) {
            cols.add(cm)
        }

        // Generate DDL
        let finder = MysqlSchemaFinder()
        let sqls = ArrayList<String>()
        for (s in finder.generateCreateSql("users", cols.iterator())) {
            sqls.add(s)
        }
        @Assert(1, sqls.size)
        @Assert(true, sqls[0].contains("create table users"))
        @Assert(true, sqls[0].contains("id bigint"))
        @Assert(true, sqls[0].contains("auto_increment"))
        @Assert(true, sqls[0].contains("name varchar(100)"))
    }
}
