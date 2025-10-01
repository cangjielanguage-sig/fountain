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
package user.service.impl

import std.reflect.*
import user.dao.UserDAO

@Bean
@BeanMeta
public class UserServiceImpl <: UserService {
    private static let log = LoggerFactory.getLogger<UserServiceImpl>()
    public func register(username: String, password: String): Int64 {
        println('username: ${username}, password: ${password}')
        executor().register(username, password)
    }
    public func changePassword(username: String, password: String): Int64 {
        try{
            println('username: ${username}, password: ${password}')
            executor().changePassword(username, password)
        }catch(e: Exception){
            e.printStackTrace()
            throw e
        }
    }
}
