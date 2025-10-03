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
package user.controller

import std.reflect.*
import stdx.encoding.json.*
import fountain.bean.*
import fountain.bean.macros.*
import fountain.mvc.*
import fountain.mvc.macros.*
import user.service.UserService
import user.model.po.*

/**
 * 把UserController UserSessionController合并成一个，加载时会抛出异常。
 * 分开两个类就能正常加载
 */
@Controller
public class UserSessionController { 
    private let userService = lookup<UserService>()

        @PostMapping[path:'/api/user/session', 
                 consumes:'application/x-www-form-urlencoded', 
                 produces:'application/json',
                 ignoreAuth: true]
    public func login(@RequestParam username: String, @RequestParam password: String): JsonValue {
        let json = 
        if (let Some((userId, token, logged)) <- userService.userSession(username, password)) {
            '''
            {
                "status": 1,
                "fields": {
                    "userId": ${userId},
                    "token": "${token}",
                    "logged": ${logged}
                }
            }'''
        } else {
            '''
            {
                "status": 0
            }'''
        }
        JsonValue.fromStr(json)
    }
    @GetMapping[path:'/api/user/session', 
                consumes:'application/x-www-form-urlencoded', 
                produces:'application/json']
    public func echoSession(@RequestHeader userId: Int64, @RequestHeader token: String): JsonValue {
        let json = '''
        {
            "status": 1,
            "fields": {
                "userId": ${userId},
                "token": "${token}"
            }
        }'''
        JsonValue.fromStr(json)
    }
}