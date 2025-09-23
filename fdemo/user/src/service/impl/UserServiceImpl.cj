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

import fountain.bean.*
import fountain.bean.macros.*
import fountain.orm.*
import user.service.UserService
import user.dao.UserDAO
import fountain.log.*

@Bean
@BeanMeta
public class UserServiceImpl <: UserService {
    private static let log = LoggerFactory.getLogger<UserServiceImpl>()
    public func register(username: String, password: String): Int64 {
        println('username: ${username}, password: ${password}')
        // executor().register(username, password)
        0
    }
}
