/*
Copyright (c) 2026 WuJingrun（吴京润）

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

import fountain::f_aspect.macros.*
import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_orm.macros.*
import fountain::f_orm.*
import fountain::f_log.*

import fountain::user.service.HelloworldService

@TransactionalService
public class HelloworldServiceImpl <: HelloworldService {
    @Transactional
    public func sayHello(name: String): Unit {
        println('BBBBBBBBBBBBBBB hello ${name}')
    }
}