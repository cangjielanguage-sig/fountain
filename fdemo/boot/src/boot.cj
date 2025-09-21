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
package common

import std.database.sql.*
import mysql.cdbc.*
import fountain.orm.{ORM, NamedDatasource}

private let _ = {=>
    let driver = DriverManager.getDriver("mysql").getOrThrow()
    let property1 = ("username", "test_user")
    let property2 = ("password", "test_user")
    let property3 = ("database", "driver_test")
    let ds = driver.open("mysql://localhost", [property1, property2, property3])
    let pool = PooledDatasource(ds)
    ORM.register(NamedDatasource(true, driver.name, pool))
}()