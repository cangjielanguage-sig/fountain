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
package fountain::fhydra

import std.collection.*

import fountain::f_data.*
import fountain::f_data.macros.DataAssist

/** 单条命中（作为 JSON-RPC result 的对象成员直接序列化） */
@DataAssist[fields props]
public class HitDto {
    public var id: String = ''
    public var payload: String = ''
    public var score: Float64 = 0.0

    public init() {
    }

    public init(id: String, payload: String, score: Float64) {
        this.id = id
        this.payload = payload
        this.score = score
    }
}

/** 检索结果：`{"hits":[…]}` */
@DataAssist[fields props]
public class HitsDto {
    public var hits: ArrayList<HitDto> = ArrayList<HitDto>()

    public init() {
    }
}

/** 单条记录：`get` 的返回；`found=false` 时其余字段为空（不返回 null） */
@DataAssist[fields props]
public class RecordDto {
    public var found: Bool = false
    public var id: String = ''
    public var payload: String = ''
    public var dense: ArrayList<Float64> = ArrayList<Float64>()

    public init() {
    }
}

/** id 分页结果：`{"ids":[…]}` */
@DataAssist[fields props]
public class IdsDto {
    public var ids: ArrayList<String> = ArrayList<String>()

    public init() {
    }
}
