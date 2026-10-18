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

import std.convert.*
import std.database.sql.*
import std.env.getVariable
import fountain::f_config.Config
import fountain::f_dbd.driver.*
import fountain::f_orm.base.*

var checks: Int64 = 0
var failures: Int64 = 0

func check(name: String, ok: Bool): Unit {
    checks += 1
    if (ok) {
        println('PASS ${name}')
    } else {
        failures += 1
        println('FAIL ${name}')
    }
}

func port(): UInt16 {
    match (getVariable('FDBM_E2E_PORT')) {
        case Some(value) => UInt16.parse(value)
        case None => 18112u16
    }
}

/**
 * f_orm 端到端：f_orm 零改动。
 *
 * `f_dbd` 通过 `dbd_driverName=postgres` 以**后端方言名**注册驱动，于是 f_orm 的
 * `orm_drivers=postgres` 同时命中 f_dbd 驱动与 `PostgresDialect`。
 * `dbd_driverName` 由应用项目配置；SQL 方言本身仍只在 fdbm 内处理。
 */
main(): Int64 {
    Config.set([
        ('orm_drivers', 'postgres'),
        ('orm_defaultDriver', 'postgres')
    ])

    let driver = match (DriverManager.getDriver('postgres')) {
        case Some(value) => value
        case None =>
            println('FAIL postgres driver is not registered (set dbd_driverName=postgres)')
            println('E2E_DONE')
            return 1
    }
    check('driver name follows backend dialect', driver.name == 'postgres')

    let url = 'fdbm://fdbm@127.0.0.1:${port()}/db0'
    ORM.register(driver, url, default: true)
    let executor = ORM.executor('postgres')
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
