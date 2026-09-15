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
package fountain::user.dao

import std.collection.*

import fountain::f_orm.*
import fountain::f_orm.macros.*

import fountain::user.model.po.*

@DAO
public interface UserDAO <: RootDAO {
    func register(username: String, password: String): Int64 {
        // executor.setSql('''
        //     insert into user_info(
        //                 ${UserPO.tableColumns().username},
        //                 ${UserPO.tableColumns().password})
        //          values(${arg(username)}, 
        //                 ${arg(password)}) 
        //     returning id'''
        // ).insert
        let user = UserPO()
        user.username = username
        user.password = password
        executor.INSERT_INTO<UserPO>(user)
    }
    func changePassword(username: String, password: String): Int64 {
        // executor.setSql('''
        //     update user_info
        //        set ${UserPO.tableColumns().password} = ${arg(password)}
        //      where ${UserPO.tableColumns().username} = ${arg(username)}'''
        // ).update
        let map = HashMap<Column, Any>()
        map[UserPO.tableColumns().password] = password
        map[UserPO.tableColumns().username] = username
        executor.UPDATE<UserPO>(map)
    }
    func findUser(id: Int64): UserPO {
        // executor.setSql('''
        //     select * 
        //       from user_info
        //      where id = ${arg(id)}'''
        // ).first<UserPO>().getOrThrow()
        executor.FROM<UserPO>().WHERE(UserPO.tableColumns().id.eq(id)).first<UserPO>().getOrThrow()
    }
    
    func findUserToMap(id: Int64): Map<String, Any> {
        // executor.setSql('''
        //     select * 
        //       from user_info
        //      where id = ${arg(id)}'''
        // ).firstToMap()
        executor.FROM<UserPO>().WHERE(UserPO.tableColumns().id.eq(id)).firstToMap()
    }

    func listUsers(): Pagination<UserPO> {
        executor.FROM<UserPO>().page(10, page: 1)
    }
    func listUsers(userLike: String): Pagination<UserPO> {
        // let page = executor.FROM<UserPO>()
        //                 .WHERE{'''
        //                         ${meet(userLike.size > 0, ' username like '){
        //                             '%${userLike}%'
        //                         }} order by id'''
        //                 }.page<UserPO>(100, page: 1)
        let page = executor.FROM<UserPO>().WHERE(meet(userLike.size > 0){UserPO.tableColumns().username.LIKE('%${userLike}%')})
                           .ORDER_BY(UserPO.tableColumns().id.ASC()).page<UserPO>(100, page: 1)
        println('QQQQQQQQQQQQQQQQQ ${page.list.size}')
        page
    }
    func deleteUser(id: Int64): Int64 {
        executor.setSql('''
            delete 
              from user_info
             where id = ${arg(id)} 
        '''
        ).delete
    }
    func findUserId(username: String, password: String): ?Int64 {
        // let task = executor.setSql('''
        //     select id, is_valid from rec_task_info limit 1 offset 0
        // ''').first<RecTaskInfo>()
        // println('TTTTTTTTTTTTTTT ${task?.isValid}')
        let med = executor.setSql('''
        select create_time, pre_amount
          from med_allocation
         limit 1 offset 0 
        ''').first<MedAllocationPO>()
        println('MMMMMMMMMMMMMMM ${med?.preAmount}')
        // let page = executor.FROM<UserPO>()
        //                 .WHERE{'''
        //                         ${meet(username.size > 0, ' username like '){
        //                             '%${username}%'
        //                         }}
        //                         ${meet(password.size > 0, ' and "password" like '){
        //                             '%${password}%'
        //                         }} order by id'''
        //                 }.page<UserPO>(100, page: 1)

        let page = executor.FROM<UserPO>().WHERE(
            AND([meet(username.size > 0){UserPO.tableColumns().username.LIKE('%${username}%')}, 
                 meet(password.size > 0){UserPO.tableColumns().password.LIKE('%${password}%')}]))
            .ORDER_BY([UserPO.tableColumns().id.ASC()]).page<UserPO>(100, page: 1)

        // println('QQQQQQQQQQQQQQQQQ ${page.list.size}')
        // let page2 = executor.FROM<UserPO>()
        //                    .WHERE{
        //                         meet(username.size > 0, ' username like '){
        //                             '%${username}%'
        //                         }
        //                         meet(password.size > 0, ' and "password" like '){
        //                             '%${password}%'
        //                         }
        //                    }.page<UserPO>(100, page: 1)
        // println('QQQQQQQQQQQQQQQQQ ${page2.list.size}')
        // let user = executor.FROM<UserPO>()
        //         .WHERE{
        //             meet(username.size > 0){
        //                 EXISTS{'select 1 from user_info where id > 0 limit 1'}
        //             }
        //         }.first<UserPO>()
        // executor.INTO<UserPO>(ignoreColumns:['id']).VALUES(user.getOrThrow()).execute()
        executor.setSql('''
            select id 
            from user_info
            where username = ${arg(username)} 
              and password = ${arg(password)}'''
        ).singleFirst<Int64>()
    }
}