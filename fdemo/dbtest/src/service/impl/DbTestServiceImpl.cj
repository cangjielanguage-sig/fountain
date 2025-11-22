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
package dbtest.service.impl


import fountain.bean.*
import fountain.bean.macros.*
import fountain.orm.*
import fountain.log.*
import dbtest.service.DbTestService
import dbtest.dao.DbTestDAO
import dbtest.model.po.*
import std.collection.*
import fountain.orm.Pagination
import fountain.orm.macros.*


//@Bean
//@BeanMeta
@TransactionalService
public class DbTestServiceImpl <: DbTestService {

    public func register(username: String, password: String): Int64 {
        println('UserServiceImpl username: ${username}, password: ${password}')

        executor().register(username, password)
        0
    }

    public func login(username: String, password: String): Int64 {
        println('login username: ${username}, password: ${password}')

        executor().getUserByLoginName(username, password)
        println('login end')
        0
    }

    public func updateSaveTimeNull(username: String, password: String): Int64 {
        executor().updateSaveTimeNull(username, password)
    }

    public func pageOrderBy(username: String, password: String): Int64 {
        executor().pageOrderBy(username, password)
        0
    }

    public func meetUserDemo(username: String, password: String): ?UserPO {
        executor().meetUserDemo(username, password)
    }

    public func listDemo(username: String, password: String): ArrayList<UserPO> {
        executor().listDemo(username, password)
    }

    public func listDemo2(username: String, password: String): ArrayList<UserPO> {
        executor().listDemo2(username, password)
    }


    public func pageDemo(username: String, password: String): Pagination<UserPO> {
        executor().pageDemo(username, password)
    }

    public func pageWithSubCondition(username: String, password: String): Pagination<UserPO> {
        executor().pageWithSubCondition(username, password)
    }


    public func firstDemo(username: String, password: String): ?UserPO {
        executor().firstDemo(username, password)
    }


    public func singleFirstDemo(username: String, password: String): String {
        executor().singleFirstDemo(username, password).getOrThrow()
    }


    public func updatePassword(id: Int64, password: String): Int64 {
        executor().updatePassword(id, password)
    }

    public func updateMap(id: Int64, map: Map<String, Any>): Int64 {
        executor().updateMap(id, map)
    }

    public func updateMapDemo(id: Int64, map: Map<String, Any>): Int64 {
        executor().updateMapDemo(id, map)
    }

    public func updateMapDemo2(map: Map<String, Any>): Int64 {
        2
    }

    public func updateMapDemo3(id: Int64): Int64 {
        3
    }


    public func updateSql(id: Int64, username: String, password: String): Int64 {
        executor().updateSql(id, username, password)
    }

    public func inDemo1(ids: ArrayList<Int64>): ArrayList<UserPO> {
        executor().inDemo1(ids)
    }

    public func inDemo2(ids: ArrayList<Int64>): ArrayList<UserPO> {
        executor().inDemo2(ids)
    }

    public func inDemo3(ids: ArrayList<Int64>): ArrayList<UserPO> {
        executor().inDemo3(ids)
    }

    public func likeDemo1(username: String): ArrayList<UserPO> {
        executor().likeDemo1(username)
    }

    public func likeDemo2(username: String): ArrayList<UserPO> {
        executor().likeDemo2(username)
    }
    public func notLikeDemo1(username: String): ArrayList<UserPO> {
        executor().notLikeDemo1(username)
    }

    public func meetDemo(username: String, password: String): ArrayList<UserPO> {
        executor().meetDemo(username, password)
    }

    public func meetDemo2(username: String, password: String): ArrayList<UserPO> {
        executor().meetDemo2(username, password)
    }


    public func whereDemo(username: String, password: String): ArrayList<UserPO> {
        executor().whereDemo(username, password)
    }



    @Transactional
    public func transactionDemo(username: String, password: String): ArrayList<UserPO> {
        deleteDemo(username, password)

        var s:Int64 = 1
        let pi: Float64 = 3.1415926
        var res3 = pi.format("0.2").toString()

        if (res3 == "3.14") {
            println("00000000======")
            s --
        }
        let a = 1 / s
        println('---------1/${s}=${a}')
        throw Exception("custom throw exception!!!")

//        println(username)
//
//        if (username.size > 0) {
//            s --
//        }
//
//        println(s)
//        let a = 1 / s
//
//        println('============ 1/${s}=${a}')
//
//        println(a)
        println('&&&&&&&&&&&&&&')

        updatePassword(1, password)

        executor().likeDemo1(username)
    }


    @Transactional
    public func transactionDemo2(username: String, password: String): ArrayList<UserPO> {

        deleteDemo(username, password)
        insertDemo(username, password)
        likeDemo1(username)
    }


    @Transactional
    public func changeTransactionDemo3(username: String, password: String): ArrayList<UserPO> {
        updatePassword(1, "事务回滚失败，快查一下")
        deleteDemo(username, password)
        throw Exception("custom throw exception!!!")

        executor().likeDemo1(username)
    }

    public func expectExceptionDemo(username: String, password: String): ArrayList<UserPO> {
        throw Exception("custom throw exception!!!")

        executor().likeDemo1(username)
    }


    public func insertDemo(username: String, password: String): Int64 {
        executor().insertDemo(username, password)
    }

    public func insertDemo2(username: String, password: String): Int64 {
        executor().insertDemo2(username, password)
    }

    public func deleteDemo(username: String, password: String): Int64 {
        executor().deleteDemo(username, password)
    }

    public func deleteDemo2(username: String, password: String): Int64 {
        executor().deleteDemo2(username, password)
    }


}