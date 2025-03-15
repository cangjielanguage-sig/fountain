/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm.orm_test

import std.time.*
import std.collection.ArrayList
import std.database.sql.*
import f_orm.macros.*
import f_data.macros.*
import f_data.*

// let _ = ORM.register(DriverTest()) // 1
let _ = ORM.register(DatasourceCreatorImpl()) // 2
@Transactional[]
//只有标准库提供ThreadLocal，这个宏才能使用
public class TestService <: RootService {
    public func query(): ArrayList<User> {
        executor().findUserList("s")
        // executor().withTx().execute<User> {exe => exe.findUserList("s")}
        // 使用这个方式就可以不用@Transactional
    }
}
@DataAssist
public class User <: ToString {
    @DataExclude[prop]
    private var _id_: Int64 = 0
    private var username: String = String.empty
    private var logged: Bool = false
    private var registerTime: DateTime = DateTime.now()

    public func toString(): String {
        "id: ${id}; username: ${username}; logged: ${logged}; registerTime: ${registerTime}"
    }
    @ORMColumn[id: true]
    public mut prop id: Int64 {
        get() {
            _id_
        }
        set(value) {
            this._id_ = value
        }
    }
    public mut prop username: String {
        get() {
            _username_
        }
        set(value) {
            _username_ = value
        }
    }
    public mut prop logged: Bool {
        get() {
            _logged_
        }
        set(value) {
            _logged_ = value
        }
    }
    public mut prop registerTime: DateTime {
        get() {
            _registerTime_
        }
        set(value) {
            _registerTime_ = value
        }
    }
}
@DAO
public interface TestDAO <: RootDAO {
    func findUserList(namePrefix: String): ArrayList<User> {
        executor.generateSql {
            args: SqlArgs => """
            select *
              from user_info
              ${`where`{
                meet(!namePrefix.isEmpty(), "username like").value("${namePrefix}%").done()
              }}
            """
        }.list<User>(User.queryMappers()) //或：.list<User>()
    }
}
public func topTest(): Unit {
    let list = TestService().query()
    println(list.size)
    println(list)
}
