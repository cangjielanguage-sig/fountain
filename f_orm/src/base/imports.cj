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
package fountain::f_orm.base


internal import std.collection.concurrent.ConcurrentHashMap
internal import fountain::f_collection.*
internal import fountain::f_exception.IllegalAccessException
internal import fountain::f_log.*
internal import fountain::f_regex.*
internal import fountain::f_orm.exception.*

public import fountain::f_base.*
public import fountain::f_bean.*
public import fountain::f_config.*
public import fountain::f_data.*
public import fountain::f_orm.wrap.ORMConfig

import fountain::f_orm.ProtectedMacros.*

// bug.md §2.12（ORM-5）：字面模式预编译为常量——原来每次调用都要插值构造 key、收集 flags、再查一次正则缓存
// （顶层 let 必须先定义后使用，故放在函数之前；注解仍贴在函数上）
private let EMPTY_LOGICAL_EXPR = #'^[\s()]*$'#.regex(solid: true)

@ORMEmbedSensitive()

func emptyLogicalExpr(cond: String): Bool {
    EMPTY_LOGICAL_EXPR.matches(cond)
}