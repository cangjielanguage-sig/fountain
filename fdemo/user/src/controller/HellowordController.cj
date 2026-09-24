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
package fountain::user.controller

import std.collection.ArrayList
import fountain::f_mvc.*
import fountain::f_mvc.macros.*
import fountain::user.model.po.*
import fountain::user.model.mvc.*
import fountain::user.service.HelloworldService

@Controller
public class HellowordController {
    private let helloworldService = lookup<HelloworldService>()
    
    @GetMapping[path:"/helloworld", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    @IgnoreSecurity
    public func helloworld(): String {
        helloworldService.sayHello('haha')
        return "helloworld"
    }
    @GetMapping[path:"/redirect/helloworld", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    @IgnoreSecurity
    public func redirectHelloworld(): Redirect {
        Redirect.found('/helloworld')
    }

    @GetMapping[path:"/helloworld2", produces:'text/plain', consumes:'application/x-www-form-urlencoded']
    @IgnoreSecurity
    public func helloworld2(): String {
        let username = "aaa"
        var zero:Int64 = 1
        var res :Int64 = 1
        if(username.size> 0){
            zero--
            println("zero new value: ${zero}")//这里能够输出 zero new value: 0
        }
        res = 1/zero
        println("res: ${res}")//这里也能输出，但是应该在上一行抛出异常
        return "helloworld"
    }
}