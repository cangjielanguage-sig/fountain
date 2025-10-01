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
import user.service.UserService

@Controller
public class UserController {
    private let userService = lookup<UserService>()

    @PostMapping[path:'/api/user/register', consumes:'application/x-www-form-urlencoded', produces:'text/plain']
    public func register(@RequestParam username: String, @RequestParam password: String): String {
        let id = userService.register(username, password).toString()
        // let json = JsonObject()
        // json.put('username', JsonString(username))
        // json.put('password', JsonString(password))
        // println(json)
        // println(JsonString(username))
        // let u = 'username'
        // println(JsonString(u))
        // json
        '''
        {
            "id": ${id},
            "username": "${username}",
            "password": "${password}"
        }
        '''
    }
    @PutMapping[path:'/api/user/changePassword', consumes:'application/x-www-form-urlencoded', produces:'text/plain']
    public func changePassword(@RequestParam username: String, @RequestParam password: String): String {
        let count = userService.changePassword(username, password).toString()
        '''
        {
            "count": ${count},
            "username": "${username}",
            "password": "${password}"
        }
        '''
    }
    @GetMapping[path:'/api/user/{id}', produces:'application/json']
    public func changePassword(@PathVariable id: Int64): JsonValue {
        let count = userService.changePassword(username, password).toString()
        '''
        {
            "count": ${count},
            "username": "${username}",
            "password": "${password}"
        }
        '''
    }
    
}