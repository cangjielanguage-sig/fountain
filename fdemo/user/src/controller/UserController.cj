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

@Controller
public class UserController {
    private let userService = lookup<UserService>()

    @PostMapping[path:'/api/user/register', 
                 consumes:'application/x-www-form-urlencoded', produces:'text/plain',
                 ignoreAuth: true]
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
    @GetMapping[path:'/api/user/{id}', produces:'application/json', consumes:'application/x-www-form-urlencoded']
    public func queryUser(@PathVariable id: Int64): JsonValue {
        println('get user by id: ${id}')
        let user = userService.queryUser(id)
        let json = '''
        {
            "status":1, 
            "fields": {
                "id": ${user.id},
                "username": "${user.username}",
                "password": "${user.password}",
                "registerTime": "${user.saveTime}"
            }
        }
        '''
        println('/api/user${id} ${json}')
        JsonValue.fromStr(json)
    }
    @GetMapping[path:'/api/users', produces:'application/json', consumes:'application/x-www-form-urlencoded']
    public func listUsers(): JsonValue {
        let list = userService.listUsers()
        let gen = StringGenerator().append('[')
        for(po in list){
            if(gen.size > 1){
                gen.append(',')
            }
            gen.append('''
                {
                    "id": ${po.id},
                    "username": "${po.username}",
                    "password": "${po.password}",
                    "registerTime": "${po.saveTime}"
                }'''
            )
        }
        gen.append(']')
        println('/api/users: ${gen}')
        let json = '''
            {
                "status": 1,
                "fields": {
                    "list": ${gen}
                }
            }
        '''
        JsonValue.fromStr(json)
    }
    @DeleteMapping[path:'/api/user/{id}', produces:'application/json', consumes:'application/x-www-form-urlencoded']
    public func deleteUser(@PathVariable id: Int64): JsonValue {
        println('delete user id is ${id}')
        let deleted = userService.deleteUser(id)
        let json = '''
        {
            "status": 1,
            "fields": {
                "deleted": ${deleted}
            }
        }'''
        JsonValue.fromStr(json)
    }
}