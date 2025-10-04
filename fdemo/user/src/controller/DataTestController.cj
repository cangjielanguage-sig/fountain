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
import fountain.data.*
import fountain.mvc.*
import fountain.mvc.macros.*
import user.service.UserService
import user.model.po.*
import user.model.*

@Controller
public class DataTestController {
    @GetMapping[path:'/api/data/test', 
                produces:'text/plain', 
                consumes:'application/x-www-form-urlencoded',
                ignoreAuth: true]
    public func test(): String {
        let data1 = TestData1()
        let data2 = DataObject<TestData2>.populate(data1)
        (data2 == TestData2()).toString()
    }
}