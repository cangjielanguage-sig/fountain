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
package dbtest.model.dataAssist

import fountain.data.*
import fountain.data.macros.*

@DataAssist[props fields]
public class UserReq {
    private var id: Int64 = 0
    private var username: String = ''
    private var password: String = ''

    public init(){}
    public init(username: String, password: String){
        this.username = username
        this.password = password
    }
    public init(id: Int64, username: String, password: String){
        this.id = id
        this.username = username
        this.password = password
    }
}

@DataAssist[props fields]
public class UserRes {
    //    private var id: Int64 = 0
    private var username: String = ''
    private var password: String = ''
    private var age: Int64 = 0

    public init(){}
    public init(username: String, password: String, age: Int64){
        this.username = username
        this.password = password
        this.age = age
    }

}


@DataAssist[props fields]
public class IdsReq {
    public var ids: ArrayList<Int64>=ArrayList<Int64>()
    public init(){}
    public init(ids: ArrayList<Int64>){
        this.ids = ids
    }

}


