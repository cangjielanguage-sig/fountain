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
package dbtest.model.mvc

import fountain.data.*
import fountain.data.macros.*
import fountain.orm.Pagination


@DataAssist[fields]
public open class BaseResponse {
    public var code: UInt16 = 0
    public var msg: String = "ok"
    public var debug: String = ""

    public init() {}
    public init(code: UInt16, msg: String) {
        super()
        this.code = code
        this.msg = msg
    }

    public init(code: UInt16, msg: String, debug: String) {
        super()
        this.code = code
        this.msg = msg
        this.debug = debug
    }


    public static func success(): BaseResponse {
        BaseResponse(0, "ok")
    }

    public static func success(msg: String): BaseResponse {
        BaseResponse(0, msg)
    }

    public static func error(msg: String): BaseResponse {
        BaseResponse(1, msg)
    }

    public static func error(msg: String, debug: String): BaseResponse {
        BaseResponse(1, msg, debug)
    }

}


@DataAssist[fields]
public open class QueryResponse<T> <: BaseResponse where T <: DataFields<T> {
    public var data: ?T = None<T>

    public static func success(data: ?T): QueryResponse<T> {
        let resp = QueryResponse<T>()
        resp.data = data
        resp
    }
}

@DataAssist[fields]
public open class ListResponse<T> <: BaseResponse where T <: DataFields<T> {
    public var list: ArrayList<T> = ArrayList<T>()

    public static func success(list: ArrayList<T>): ListResponse<T> {
        let resp = ListResponse<T>()
        resp.list = list
        resp
    }
}





