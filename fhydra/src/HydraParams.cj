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

/** upsert 参数：过滤字段用显式三件套，避免 JSON 嵌套映射的不确定性 */
@DataAssist[fields props]
public class UpsertParam {
    public var collection: String = ''
    public var id: String = ''
    public var payload: String = ''
    public var dense: Array<Float64> = Array<Float64>()
    /** f32 小端原始字节的 Base64；非空时优先于 `dense` */
    public var denseB64: String = ''
    public var kind: String = ''
    public var saveDay: String = ''
    public var tags: String = ''
    /** 命名 dense（方案 C）：标题向量 */
    public var titleDense: ArrayList<Float64> = ArrayList<Float64>()
    /** 命名 dense（方案 C）：正文字向量 */
    public var contentDense: ArrayList<Float64> = ArrayList<Float64>()
    /** 业务时间（epoch 秒），ids 排序用 */
    public var saveTime: Int64 = 0

    public init() {
    }
}

@DataAssist[fields props]
public class GetParam {
    public var collection: String = ''
    public var id: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class RemoveParam {
    public var collection: String = ''
    public var id: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class SearchParam {
    public var collection: String = ''
    /** `dense`（默认）/ `title` / `content` */
    public var field: String = 'dense'
    public var dense: Array<Float64> = Array<Float64>()
    /** f32 小端原始字节的 Base64；非空时优先于 `dense` */
    public var denseB64: String = ''
    public var limit: Int64 = 10
    public var kind: String = ''
    public var saveDay: String = ''
    public var tags: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class SparseParam {
    public var collection: String = ''
    public var tokenIds: Array<Int64> = Array<Int64>()
    public var weights: Array<Float64> = Array<Float64>()
    public var limit: Int64 = 10
    public var kind: String = ''
    public var saveDay: String = ''
    public var tags: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class CollectionParam {
    public var collection: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class IdsParam {
    public var collection: String = ''
    public var offset: Int64 = 0
    public var limit: Int64 = 100

    public init() {
    }
}

@DataAssist[fields props]
public class BuildIndexParam {
    public var collection: String = ''
    public var clusters: Int64 = 0

    public init() {
    }
}

@DataAssist[fields props]
public class RerankParam {
    public var collection: String = ''
    public var ids: ArrayList<String> = ArrayList<String>()
    public var colbert: Array<Array<Float64>> = Array<Array<Float64>>()

    public init() {
    }
}

@DataAssist[fields props]
public class ExportParam {
    public var collection: String = ''
    public var targetCollection: String = ''

    public init() {
    }
}

@DataAssist[fields props]
public class TtlParam {
    public var collection: String = ''
    public var seconds: Int64 = 0

    public init() {
    }
}
