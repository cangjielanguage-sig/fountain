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
package fountain::f_dbd.multid

import std.collection.ArrayList
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.driver.DbdUrl
import fountain::f_dbd.exception.DbdException

/**
 * 多节点连接串（设计 §6.2）：
 *
 * `multidbm://user1:pwd1@host1:port1,user2:pwd2@host2:port2/database_name`
 *
 * 同时接受 `multidbd://`（与驱动名一致）——避免"驱动叫 `multidbd`、连接串却必须写 `multidbm`"
 * 这一需求原文自带的陷阱。节点顺序 = URL 中出现顺序 = 权重顺序。
 */
public class MultiDUrl {
    static const SCHEME_BM: String = 'multidbm://'
    static const SCHEME_BD: String = 'multidbd://'

    /** 节点列表（顺序与 URL 一致）。 */
    public let nodes: Array<DbdUrl>
    /** 逻辑库名（第一个路径段）。 */
    public let database: String

    private init(nodes: Array<DbdUrl>, database: String) {
        this.nodes = nodes
        this.database = database
    }

    /** 解析；任何不合法都抛 `DbdException(CONFIG)`（包含节点数 0 / 某节点非法）。 */
    public static func parse(url: String): MultiDUrl {
        let rest = match (schemeRest(url)) {
            case Some(value) => value
            case None => throw DbdException(DbdErrorCode.CONFIG,
                'illegal multid url \'${url}\': scheme must be multidbm or multidbd')
        }
        let slash = match (rest.indexOf('/')) {
            case Some(index) => index
            case None => throw DbdException(DbdErrorCode.CONFIG,
                'illegal multid url \'${url}\': database is missing')
        }
        let nodesPart = rest[0..slash]
        let database = firstSegment(rest[slash + 1..rest.size])
        if (database.isEmpty()) {
            throw DbdException(DbdErrorCode.CONFIG, 'illegal multid url \'${url}\': database is empty')
        }
        if (nodesPart.isEmpty()) {
            throw DbdException(DbdErrorCode.CONFIG, 'illegal multid url \'${url}\': node list is empty')
        }
        let nodes = ArrayList<DbdUrl>()
        for (node in nodesPart.split(',')) {
            let text = node.trimAscii()
            if (text.isEmpty()) {
                throw DbdException(DbdErrorCode.CONFIG,
                    'illegal multid url \'${url}\': empty node in the node list')
            }
            nodes.add(parseNode(text, url, database))
        }
        if (nodes.isEmpty()) {
            throw DbdException(DbdErrorCode.CONFIG, 'illegal multid url \'${url}\': node list is empty')
        }
        MultiDUrl(nodes.toArray(), database)
    }

    /** 非法 URL → `None`（不抛）。 */
    public static func tryParse(url: String): ?MultiDUrl {
        try {
            Some(parse(url))
        } catch (_: Exception) {
            None<MultiDUrl>
        }
    }

    /**
     * 单个节点复用单节点驱动的解析口径；节点串只带 `[user:pass@]host[:port]`，
     * 库名取多节点 URL 的那一个（拼进节点 URL 后再解析）。
     */
    private static func parseNode(node: String, url: String, database: String): DbdUrl {
        try {
            DbdUrl.parse('fdbm://${node}/${database}')
        } catch (e: DbdException) {
            throw DbdException(DbdErrorCode.CONFIG,
                'illegal multid url \'${url}\': bad node \'${node}\': ${e.message}', cause: e)
        }
    }

    /** `multidbm://` / `multidbd://` → scheme 之后的剩余部分；其它 scheme → `None`。 */
    private static func schemeRest(url: String): ?String {
        if (url.startsWith(SCHEME_BM)) {
            return Some(url[SCHEME_BM.size..url.size])
        }
        if (url.startsWith(SCHEME_BD)) {
            return Some(url[SCHEME_BD.size..url.size])
        }
        None<String>
    }

    /** 第一个路径段（与 `DbdUrl` 的 database 口径一致：忽略后续 `/` 之后的部分）。 */
    private static func firstSegment(path: String): String {
        match (path.indexOf('/')) {
            case Some(index) => path[0..index]
            case None => path
        }
    }
}
