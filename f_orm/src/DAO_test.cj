// /**
//    Copyright (c) 2022 WuJingrun（吴京润）
//    fountain is licensed under Mulan PSL v2.
//    You can use this software according to the terms and conditions of the Mulan PSL v2.
//    You may obtain a copy of Mulan PSL v2 at:
//            http://license.coscl.org.cn/MulanPSL2
//    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
//    See the Mulan PSL v2 for more details.
//  */

package f_orm

// import std.time.*
// import std.collection.ArrayList
// import std.database.sql.*
// import orm.macros.*
// import orm.exception.*
// // let _ = ORM.register(DriverTest()) // 1
// let _ = ORM.register(DatasourceCreatorImpl()) // 2
// public func topTest(): Unit {
//     let list = TestService().query()
//     println(list.size)
//     println(list)
// }
// // @Transactional[]
// // public class TestService <: RootService {
// //     public func query(): ArrayList<User> {
// //         executor().findUserList("s")
// //     }
// // }
// public class TestService <: RootService {
//     public func query(): ArrayList<String> {
//         func __callee__() {
//             // executor().findUserList("s")
//             ArrayList<String>()
//         }
//         var committing = false
//         let _exe_ = this.executor("")
//         let r = try (exe = _exe_) {
//             let tx = exe.createTransaction(propagation: Propagation.Required)
//             tx.begin()
//             let result = tx.call(__callee__)
//             committing = true
//             _exe_.commit()
//             result
//         } catch (e: Exception) {
//             throw e
//         }
//         r
//     }
// }
// @QueryMappersGenerator[id]
// public class User <: ToString {
//     private var _id_: Int64 = 0
//     private var _username_: String = String.empty
//     private var _logged_: Bool = false
//     private var _registerTime_: DateTime = DateTime.now()
//     public func toString(): String {
//         "id: ${id}; username: ${username}; logged: ${logged}; registerTime: ${registerTime}"
//     }
//     public mut prop id: Int64 {
//         get() {
//             _id_
//         }
//         set(value) {
//             this._id_ = value
//         }
//     }
//     public mut prop username: String {
//         get() {
//             _username_
//         }
//         set(value) {
//             _username_ = value
//         }
//     }
//     public mut prop logged: Bool {
//         get() {
//             _logged_
//         }
//         set(value) {
//             _logged_ = value
//         }
//     }
//     public mut prop registerTime: DateTime {
//         get() {
//             _registerTime_
//         }
//         set(value) {
//             _registerTime_ = value
//         }
//     }
// }
// @DAO
// public interface TestDAO <: RootDAO {
//     func findUserList(namePrefix: String): ArrayList<User> {
//         executor.generateSql {
//             args: SqlArgs => """
//             select *
//               from user_info
//               ${args.meet(!namePrefix.isEmpty(), "username like", "${namePrefix}%", prefix: "where")}
//             """
//         }.list<User>(User.queryMappers())
//     }
// }
