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
package dbtest.service

import fountain.orm.RootService
import dbtest.model.po.*
import std.collection.*
import fountain.orm.Pagination

public interface DbTestService <: RootService {
    func register(username: String, password: String): Int64
    func login(username: String, password: String): Int64
    func updateSaveTimeNull(username: String, password: String): Int64
    func pageOrderBy(username: String, password: String): Int64
    func meetUserDemo(username: String, password: String): ?UserPO
    func listDemo(username: String, password: String): ArrayList<UserPO>
    func listDemo2(username: String, password: String): ArrayList<UserPO>
    func whereDemo(username: String, password: String): ArrayList<UserPO>

    func pageDemo(username: String, password: String): Pagination<UserPO>
    func pageWithSubCondition(username: String, password: String): Pagination<UserPO>
    func firstDemo(username: String, password: String): ?UserPO
    func singleFirstDemo(username: String, password: String): String
    func updatePassword(id: Int64, password: String): Int64
    func updateMap(id: Int64, map: Map<String, Any>): Int64
    func updateMapDemo(id: Int64, map: Map<String, Any>): Int64
    func updateMapDemo2(map: Map<String, Any>): Int64
    func updateMapDemo3(id: Int64): Int64

    func updateSql(id: Int64, username: String, password: String): Int64
    func inDemo1(ids: ArrayList<Int64>): ArrayList<UserPO>
    func inDemo2(ids: ArrayList<Int64>): ArrayList<UserPO>
    func inDemo3(ids: ArrayList<Int64>): ArrayList<UserPO>

    func likeDemo1(username: String): ArrayList<UserPO>
    func likeDemo2(username: String): ArrayList<UserPO>
    func notLikeDemo1(username: String): ArrayList<UserPO>

    func meetDemo(username: String, password: String): ArrayList<UserPO>
    func meetDemo2(username: String, password: String): ArrayList<UserPO>

    func transactionDemo(username: String, password: String): ArrayList<UserPO>
    func transactionDemo2(username: String, password: String): ArrayList<UserPO>
    func changeTransactionDemo3(username: String, password: String): ArrayList<UserPO>
    func expectExceptionDemo(username: String, password: String): ArrayList<UserPO>
    func insertDemo(username: String, password: String): Int64
    func insertDemo2(username: String, password: String): Int64
    func deleteDemo(username: String, password: String): Int64
    func deleteDemo2(username: String, password: String): Int64


}