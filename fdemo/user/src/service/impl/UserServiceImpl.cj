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
package fountain::user.service.impl

import std.collection.Map
import std.reflect.*

import fountain::f_aspect.macros.*
import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_orm.macros.*
import fountain::f_orm.*
import fountain::f_log.*

import fountain::user.service.UserService
import fountain::user.dao.UserDAO
import fountain::user.model.entity.*
import fountain::user.model.po.*
import fountain::user.model.mvc.*

// @Bean
// @BeanMeta
@TransactionalService//如果不需要事务控制可以用@Bean修饰
public class UserServiceImpl <: UserService {
    private static let log = LoggerFactory.getLogger<UserServiceImpl>()
    public func register(username: String, password: String): Int64 {
        println('username: ${username}, password: ${password}')
        executor().register(username, password)
    }
    public func changePassword(username: String, password: String): Int64 {
        println('username: ${username}, password: ${password}')
        executor().changePassword(username, password)
    }
    public func queryUser(id: Int64): UserPO {
        try{
            // let map = executor().findUserToMap(id)
            // for((k, n) in map){
            //     println("${k} : ${n as ToString}")
            // }
            let po = executor().findUser(id)
            po
        }catch(e: Exception){
            e.printStackTrace()
            throw e
        }
    }
    public func listUsers(): UserList {
        let page = executor().listUsers()
        UserList(1, page)
    }
    public func deleteUser(id: Int64): Int64 {
        println('id: ${id}')
        executor().deleteUser(id)
    }

    @Transactional//仅做演示，此函数只有查询，不需要事务控制，如果事务生效，控制台会输出日志
    public func userSession(username: String, password: String): ?(Int64, String, Bool) {
        let exe = executor()
        exe.listUsers(username)
        UserEntity(username, password).makeSession(exe.findUserId)
    }
    public func userSessionLog(username: String, password: String): ?(Int64, String, Bool){
        try{
            let user = UserPO()
            user.id = 1
            user.password = '24124141324'
            //DirtyTag.setBeforeDirty<UserPO>()
            user.username = 'asdfsafadfsfsdf'
            executor().UPDATE<UserPO>(user, dirty: true)
        }catch(e: Exception){
            e.printStackTrace()
        }
        None<(Int64, String, Bool)>
    }
}
