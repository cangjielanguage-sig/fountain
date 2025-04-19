/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean

internal import std.collection.{HashMap, TreeMap, LinkedList, ArrayList}
internal import std.collection.concurrent.ConcurrentHashMap
internal import std.convert.*
internal import std.process.{Process, CurrentProcess}
internal import std.reflect.*
internal import std.sync.{AtomicInt64, AtomicBool, AtomicOptionReference, ReentrantMutex}
internal import f_base.*
internal import f_collection.TreeSet
internal import f_config.Config
internal import f_data.*
internal import f_regex.*
public import f_bean.exception.*

internal func toRegex(wildcard: String): Regex {
    wildcard.replace('*', '.*').replace('?', '.?').regex()
}
/**
 * 初始化时使用命令行参数--initBeansIfNeed
 */
internal let shouldInitBean = Config.getValue<Bool>('shouleInitBean') ?? true