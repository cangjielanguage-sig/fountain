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
package user.dao

import std.collection.*

import fountain.orm.*
import fountain.orm.macros.*

import user.model.po.*

@DAO
public interface UserDAO <: RootDAO {
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
    func changePassword(username: String, password: String): Int64 {
        executor.setSql('''
            update user_info
               set "password" = ${arg(password)}
             where username = ${arg(username)}'''
        ).update
    }
    func findUser(id: Int64): UserPO {
        executor.setSql('''
            select * 
              from user_info
             where id = ${arg(id)}'''
        ).first<UserPO>().getOrThrow()
    }
    
    func findUserToMap(id: Int64): Map<String, Any> {
        executor.setSql('''
            select * 
              from user_info
             where id = ${arg(id)}'''
        ).firstToMap()
    }
    func listUsers(): ArrayList<UserPO> {
        executor.setSql('''
            select * 
              from user_info'''
        ).list<UserPO>()
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
        executor.setSql('''
            select id 
            from user_info
            where username = ${arg(username)} and 
                password = ${arg(password)}'''
        ).singleFirst<Int64>()
    }
}