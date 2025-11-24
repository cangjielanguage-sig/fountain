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
package dbtest.dao

import fountain.orm.*
import fountain.orm.macros.*
import dbtest.model.po.*
import fountain.orm.Pagination
import std.time.*

@DAO
public interface DbTestDAO <: RootDAO {
    func register(username: String, password: String): Int64 {
        executor.setSql('''
            insert into user_info(
                        username,
                        password)
                 values(${arg(username)},
                        ${arg(password)})
            returning id'''
        ).insert

    }
    func getUserByLoginName(username: String, password: String): ?UserPO {
        println("dao begin")
        executor.setSql('''
            select *
              from user_info
             where username = ${arg(username)}
              '''
        ).first<UserPO>()

    }
    func updateSaveTimeNull(username: String, password: String): Int64 {
        let time = None<DateTime>
        return executor.setSql('''
            update user_info
               set save_time = ${arg(time)}
             where username = ${arg(username)}'''
        ).update
    }


    func pageOrderBy(username: String, password: String): Int64 {
        let resOrderBy = executor.FROM<UserPO>()
                .WHERE{
                    meet(username.size > 0, ' username like '){
                        '%${username}%'
                    }
                }
                .ORDER_BY{ "id" }
                .page<UserPO>(10, page: 1)

        1
    }

// usernamke like
    func meetUserDemo(username: String, password: String): ?UserPO {
        executor.FROM<UserPO>()
                .WHERE{
                    meet(username.size > 0, ' username like '){
                        '%${username}%'
                    }
                    meet(password.size > 0, ' and password like'){
                        '%${password}%'
                    }
                }
                .ORDER_BY{ "id" }
                .first<UserPO>()
    }

// list demo
    func listDemo(username: String, password: String): ArrayList<UserPO> {
        executor.FROM<UserPO>()
                .WHERE{
                    meet(username.size > 0, ' username like '){
                        '%${username}%'
                    }
                }
                .ORDER_BY{ "id" }
                .LIMIT(3)
                .list<UserPO>()
    }


    func listDemo2(username: String, password: String): ArrayList<UserPO> {
        let statusList = ArrayList<String>(["S", "F"])
        let id = 0

        executor.setSql('''
            select *
              from sys_user
              where
              id > ${arg(id)}
              and status in ${arg(statusList)}
              order by user_type desc
              '''
        ).list<UserPO>()


    }


// page demo
    func pageDemo(username: String, password: String): Pagination<UserPO> {
        executor.FROM<UserPO>()
                .WHERE{
                    meet(username.size > 0, ' username like '){
                        '%${username}%'
                    }
                }
                .ORDER_BY{ "id" }
                .page<UserPO>(3, page: 1)
    }


// get first record
    func firstDemo(username: String, password: String): ?UserPO {
        executor.FROM<UserPO>()
                .WHERE("username like '%${username}%'")
                .ORDER_BY{ "id" }
                .first<UserPO>()
    }

// get value of first reacord
    func singleFirstDemo(username: String, password: String): ?String {
        executor.FROM<UserPO>()
                .WHERE( "username like '%${username}%'" )
                .ORDER_BY{ "id" }
                .singleFirst<String>('username')
    }


    func customSqlPageDemo(username: String, password: String): Pagination<UserPage> {
        // sql 实际上会很复杂
        let sql = "select password,sum(id) as total from user_info group by password order by password"
        executor.page<UserPage>(sql, 3, page: 1)
    }

    func pageWithSubCondition(username: String, password: String): Pagination<UserPO> {
        let id1 = 1
        let id2 = 2
        executor.FROM<UserPO>()
                .WHERE(
                        '''
"password" = ${arg(password)} and (id = ${arg(id1)} or id = ${arg(id2)})
'''
                )
                .page<UserPO>(10, page: 1)
    }


    func updatePassword(id: Int64, password: String): Int64 {
        let pattern = "yyyy/MM/dd HH:mm:ssSSS OO"
        let datetime = DateTime.of(
                year: 2024,
                month: May,
                dayOfMonth: 22,
                hour: 12,
                minute: 34,
                second: 56,
                nanosecond: 789000000,
        )
//        let str = datetime.format(pattern) // 支持传入日期的字符串格式
        executor.UPDATE<UserPO>()
                .SET{ "password=${arg(password)},save_time=${arg(datetime)}" }
                .WHERE("id=${arg(id)}")
                .execute()
    }


    func updateMap(id: Int64, map: Map<String, Any>): Int64 {
        let map2 = HashMap<String, Any>()
        map2["password"] = "123"
        map2["username"] = "admin"


        let username = (map["username"] as String).getOrThrow()
        let password = (map["password"] as String).getOrThrow()
        let time = None<DateTime> // 测试值可为 null， save_time=null
        let newUsername = Option<String>.Some(username) // 测试值可为 Option， username=?String
        executor.setSql('''
            update user_info
            set save_time = ${arg(time)},  username=${arg(newUsername)},password=${arg(password)}
            where id = ${arg(id)} '''
        ).update

//
////        这个要慢一些，因为尾闭包返回的set子句会经历一次从字符串转换为Tokens，再遍历tokens，最后再从Tokens转换成SET 子句的字符串。
//        executor.UPDATE<UserPO>()
//        .SET(map2){ 'password=:password,username=:username' }
//                .WHERE('id=${arg(id)}')
//                .execute()
    }

    func updateMapDemo(id: Int64, map: Map<String, Any>): Int64 {
        10
    }


    func updateSql(id: Int64, username: String, password: String): Int64 {
        let time = None<DateTime> // 测试值可为 null， save_time=null
        let newUsername = Option<String>.Some(username) // 测试值可为 Option， username=?String

        executor.setSql('''
            update user_info
            set save_time = ${arg(time)},  username=${arg(newUsername)},password=${arg(password)}
            where id = ${arg(id)} '''
        ).update
    }


    func inDemo1(ids: ArrayList<Int64>): ArrayList<UserPO> {
        executor.FROM<UserPO>().WHERE("id in ${arg(ids)}").ORDER_BY{ "id" }.list<UserPO>()
    }

    func inDemo2(ids: ArrayList<Int64>): ArrayList<UserPO> {
        executor.setSql('''
            select *
              from user_info
              where id in ${arg(ids)}
              order by id asc
              '''
        ).list<UserPO>()
    }

    func inDemo3(ids: ArrayList<Int64>): ArrayList<UserPO> {
        executor.setSql('''
            select *
              from user_info
              where id ${IN(ids)}
              order by id asc
              '''
        ).list<UserPO>()
    }


    func likeDemo1(username: String): ArrayList<UserPO> {
        executor.FROM<UserPO>()
                .WHERE( "username like ${arg('%${username}%')}" )
                .ORDER_BY{ "id" }
                .list<UserPO>()
    }

    func likeDemo2(username: String): ArrayList<UserPO> {
        executor.setSql('''
            select *
              from user_info
              where username like ${arg('%${username}%')}
              order by id asc
              '''
        ).list<UserPO>()
    }

    func notLikeDemo1(username: String): ArrayList<UserPO> {
        executor.setSql('''
            select *
              from user_info
              where username not like ${arg('%${username}%')}
              order by id asc
              '''
        ).list<UserPO>()
    }

    func meetDemo(username: String, password: String): ArrayList<UserPO> {
        let userIdNotList: Array<Int64> = [4, 5]

        let userIdList: Array<Int64> = [1, 2, 3, 4, 5]
        executor.FROM<UserPO>()
                .WHERE{
                    meet(userIdList.size > 0){ EXISTS{ 'select 1 from user_info where id > 1' } }
                    meet(userIdList.size > 0, 'and id ').IN(userIdList)
                    meet(userIdNotList.size > 0, 'and id').NOT_IN(userIdNotList)
                    meet(userIdList.size > 0, 'and id').BETWEEN(1, 20)
                    meet(username.size > 0, 'and username like '){ '%adm%' }
                    meet(username.size > 0, 'and username like ', '%${username}%')
                    meet(password.size > 0, 'and password like ').value{ '%${password}%' }.done()
                    meet(username.size > 0, 'and username not like '){ '123' }
                }.list<UserPO>()

    }

    func meetDemo2(username: String, password: String): ArrayList<UserPO> {
        executor.FROM<UserPO>()
                .WHERE{
                    meet(username.size > 0, ' and username like '){
                        '%${username}%'
                    }
                    meet(password.size > 0, ' and password like '){
                        '%${password}%'
                    }
                }
                .list<UserPO>()
    }

    func whereDemo(username: String, password: String): ArrayList<UserPO> {
        executor.FROM<UserPO>()
                .WHERE('''
            ${meet(username.size > 0, ' and username like '){
                    '%${username}%'
                }}

            ${meet(password.size > 0,' and password like '){
                        '%${password}%'
                    }}
            '''
                )
                .ORDER_BY({=>"id"})
                .list<UserPO>()
    }

    func insertDemo(username: String, password: String): Int64 {

        let user = UserPO()
        user.username = username
        user.password = password
        user.saveTime = None<DateTime>
//        user.createTime = DateTime.now()

//        executor.INTO<T>().VALUES<D>(value)
// value的类型就是D，T <: QueryMappersInit<T>    D <: ObjectData<D>，遍历D.queryMappers取得所有列名，再从列名映射到属性名从value取值。构造insert into table_name(<columns>)values(.....)

        executor.INTO<UserPO>(ignoreColumns:['id'])
                .VALUES<UserPO>(user)
                .execute()

//        还可以executor.INTO<T1>().SELECT<T2>(<columns>){from => from.WHERE....}
    }


    func insertDemo2(username: String, password: String): Int64 {
        let saveTime = DateTime.now()
        executor.setSql('''
            insert into user_info(
                        username,
                        password,
                        save_time
                        )
                 values(${arg(username)},
                        ${arg(password)},
                        ${arg(saveTime)}
                        )
            returning id'''
        ).insert
    }

    func deleteDemo(username: String, password: String): Int64 {
        executor.FROM<UserPO>()
                .WHERE("username=${arg(username)}")
                .DELETE()
    }

    func deleteDemo2(username: String, password: String): Int64 {
        executor.setSql('''
            delete from user_info where username=${arg(username)}
            '''
        ).delete
    }


}