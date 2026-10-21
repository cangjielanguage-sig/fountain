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
package postgres_e2e_orm_client

import std.collection.ArrayList
import std.convert.*
import std.database.sql.*
import std.env.getVariable
import fountain::f_config.Config
import fountain::f_data.macros.*
import fountain::f_dbd.driver.*
import fountain::f_orm.base.*
import fountain::f_orm.macros.*

var checks: Int64 = 0
var failures: Int64 = 0

/** 实体 e2e 的 PO（表名显式指定为 `orm_item`；`id` 是自增主键）。 */
@DataAssist[fields tostring]
@QueryMappersGenerator['orm_item']
public class OrmItem {
    @ORMField[true 'id'] public var id: Int64 = 0
    @ORMField['name'] public var name: String = ''
}

func check(name: String, ok: Bool): Unit {
    checks += 1
    if (ok) {
        println('PASS ${name}')
    } else {
        failures += 1
        println('FAIL ${name}')
    }
}

func checkInt(name: String, actual: Int64, expected: Int64): Unit {
    check('${name} (${actual} == ${expected})', actual == expected)
}

func port(): UInt16 {
    match (getVariable('FDBM_E2E_PORT')) {
        case Some(value) => UInt16.parse(value)
        case None => 18112u16
    }
}

func backend(): String {
    match (getVariable('FDBM_E2E_BACKEND')) {
        case Some(value) => value
        case None => 'postgres'
    }
}

func isMySql(): Bool {
    backend() == 'mysql'
}

/**
 * f_orm 端到端：f_orm 零改动。
 *
 * `f_dbd` 通过 `dbd_driverName=<backend>` 以**后端方言名**注册驱动，于是 f_orm 的
 * `orm_drivers=<backend>` 同时命中 f_dbd 驱动与对应方言（Postgres / MySql）。
 * `dbd_driverName` 由应用项目配置；SQL 方言本身仍只在 fdbm 内处理。
 */
main(): Int64 {
    let name = backend()
    Config.set([
        ('orm_drivers', name),
        ('orm_defaultDriver', name)
    ])

    let driver = match (DriverManager.getDriver(name)) {
        case Some(value) => value
        case None =>
            println('FAIL ${name} driver is not registered (set dbd_driverName=${name})')
            println('E2E_DONE')
            return 1
    }
    check('driver name follows backend dialect', driver.name == name)

    let url = 'fdbm://fdbm@127.0.0.1:${port()}/app'
    ORM.register(driver, url, default: true)
    let executor = ORM.executor(name)
    try {
        check('orm ddl drop', executor.setSql('drop table if exists t_orm').update >= 0)
        check('orm ddl create', executor.setSql(
            'create table t_orm (id bigint primary key, name text)').update >= 0)

        check('orm insert literal', executor.setSql(
            "insert into t_orm (id, name) values (1, 'orm')").update == 1)
        check('orm select literal', executor.singleFirst<Int64>(
            'select id from t_orm where id = 1', 0) == Some(1))

        let boundId: Int64 = 2
        let boundName: String = 'two'
        check('orm insert bound', executor.setSql(
            'insert into t_orm (id, name) values (?, ?)').add(boundId).add(boundName).update == 1)
        check('orm select bound', executor.singleFirst<String>(
            'select name from t_orm where id = 2', 0) == Some('two'))

        check('orm update', executor.setSql(
            "update t_orm set name = 'updated' where id = 1").update == 1)
        check('orm update visible', executor.singleFirst<String>(
            'select name from t_orm where id = 1', 0) == Some('updated'))

        // `singleFirst(sql, column)` 走方言的 `limit ? offset ?`，由 fdbm 绑定成整数
        check('orm dialect limit', executor.singleFirst<Int64>(
            'select id from t_orm order by id', 0) == Some(1))

        check('orm delete', executor.setSql('delete from t_orm where id = 2').update == 1)
        check('orm delete visible', executor.singleFirst<Int64>(
            'select id from t_orm where id = 2', 0).isNone())

        entityFlow()
    } finally {
        executor.close()
        ORM.close()
    }
    println('checks=${checks}, failures=${failures}')
    println('E2E_DONE')
    if (failures == 0) {
        0
    } else {
        1
    }
}

/**
 * 实体 / 分页 / 更新 / 删除（design.md D8）。
 *
 * 实体插入走 `INSERT_INTO` 生成器（PostgreSQL 方言会追加 `returning id`），
 * 用 `executor.insert` 拿物理库返回的 `lastInsertId`；分页覆盖 `count(*)` 与派生表分页。
 */
func entityFlow(): Unit {
    // `Column.toString()` 依赖 SqlExecutor 的线程上下文；每次普通语句执行后上下文会被清空，
    // 因此构造带列名的子句前要重新取一次 executor（同一实例，只是重置上下文）。
    check('orm entity ddl drop', ORM.executor().setSql('drop table if exists orm_item').update >= 0)
    let ddl = if (isMySql()) {
        'create table orm_item (id bigint auto_increment primary key, name varchar(64))'
    } else {
        'create table orm_item (id bigserial primary key, name varchar(64))'
    }
    check('orm entity ddl create', ORM.executor().setSql(ddl).update >= 0)

    let ids = ArrayList<Int64>()
    var i = 0
    while (i < 5) {
        let item = OrmItem()
        item.name = 'orm${i}'
        let exe = ORM.executor()
        let clause = exe.INSERT_INTO<OrmItem>(ignoreColumns: [OrmItem.tableColumns().id])
        clause.VALUES<OrmItem>(item)
        let id = exe.setSql(clause.toString()).insert
        check('orm entity insert ${i} (${id} > 0)', id > 0)
        ids.add(id)
        i += 1
    }

    check('orm entity read back', ORM.executor().setSql(
        'select name from orm_item where id = ?').add(ids[0]).singleFirst<String>(0) == Some('orm0'))
    checkInt('orm entity count', ORM.executor().FROM<OrmItem>().count(), 5)

    let pagination = ORM.executor().FROM<OrmItem>()
        .ORDER_BY([OrmItem.tableColumns().id.ASC()])
        .page<OrmItem>(2, page: 2)
    checkInt('orm page rows', pagination.rows, 5)
    checkInt('orm page pages', pagination.pages, 3)
    checkInt('orm page list size', pagination.list.size, 2)

    let values: Array<(Column, Any)> = [(OrmItem.tableColumns().name, 'updated')]
    checkInt('orm entity update', ORM.executor().UPDATE<OrmItem, Int64>(values, ids[0]), 1)
    check('orm entity update visible', ORM.executor().setSql(
        'select name from orm_item where id = ?').add(ids[0]).singleFirst<String>(0) ==
        Some('updated'))

    let deleted = ORM.executor().FROM<OrmItem>()
        .WHERE(OrmItem.tableColumns().id.eq(ids[0]))
        .DELETE()
    checkInt('orm entity delete', deleted, 1)
    check('orm entity delete visible', ORM.executor().setSql(
        'select id from orm_item where id = ?').add(ids[0]).singleFirst<Int64>(0).isNone())
}
