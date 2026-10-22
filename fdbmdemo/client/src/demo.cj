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
package fountain::fdbmdemo_client

import std.collection.ArrayList
import std.database.sql.Connection
import fountain::f_config.Config
import fountain::f_dbd.MultiDatasource
import fountain::f_dbd.multid.multiDDriver

/**
 * f_dbd 演示主体（配合同目录 ../boot.sh 启动的两个 fdbm 实例 + WSL Ubuntu 24.04 的 PostgreSQL）：
 *
 * 1. **负载均衡**：`MultiDatasource` 挂两个 fdbm 节点（8112 / 8113），客户端权重
 *    `roundrobin,1,3`。两实例配置几乎一致，唯一区别是 fdbm-2 额外配置了逻辑库 `spare`，
 *    于是 `show databases` 的返回就是"这次连接落在哪个实例"的探针。
 * 2. **数据分片**：`t_order` 配 `fdbm_partition__t_order=demo,hash,id`。插入按分库键路由到
 *    demo_0 / demo_1；带分库键的点查只打一个库；不带分库键的 SELECT 广播合并（多段游标）。
 * 3. **读写分离**：fdbm 节点权重 n1=`w,1;r,0`（只写）、n2=`w,0;r,1`（只读），
 *    且 n2 用的 postgres 账号 `fdbm_r` 只有 SELECT 权限 —— 写语句若被路由到读节点会直接
 *    permission denied（用 `../boot.sh check` 核对物理库）。
 */

const FDBM1_PORT: UInt16 = 8112u16
const FDBM2_PORT: UInt16 = 8113u16

var checks: Int64 = 0
var failures: Int64 = 0

func check(name: String, ok: Bool): Unit {
    checks += 1
    if (ok) {
        println('PASS ${name}')
    } else {
        failures += 1
        println('FAIL ${name}')
    }
}

func checkInt(name: String, actual: Int64, expected: Int64): Unit {
    check('${name} (${actual} == ${expected})', actual == expected)
}

func checkText(name: String, actual: String, expected: String): Unit {
    check('${name} (${actual} == ${expected})', actual == expected)
}

func execUpdate(connection: Connection, sql: String): Int64 {
    let statement = connection.prepareStatement(sql)
    try {
        statement.update().rowCount
    } finally {
        statement.close()
    }
}

/** 单行单列文本；无行返回 None。 */
func firstText(connection: Connection, sql: String): ?String {
    let statement = connection.prepareStatement(sql)
    try {
        let result = statement.query()
        try {
            if (result.next()) {
                Some(result.get<String>(0))
            } else {
                None<String>
            }
        } finally {
            result.close()
        }
    } finally {
        statement.close()
    }
}

/** 第一列的字符串集合（`show databases` 等内存游标）。 */
func stringColumn(connection: Connection, sql: String): Array<String> {
    let statement = connection.prepareStatement(sql)
    try {
        let result = statement.query()
        try {
            let names = ArrayList<String>()
            while (result.next()) {
                names.add(result.get<String>(0))
            }
            names.toArray()
        } finally {
            result.close()
        }
    } finally {
        statement.close()
    }
}

/** 实例探针：fdbm-1 只有逻辑库 demo，fdbm-2 额外有 spare。 */
func probeInstance(connection: Connection): String {
    if (stringColumn(connection, 'show databases').contains('spare')) {
        'fdbm-2'
    } else {
        'fdbm-1'
    }
}

// ---------------------------------------------------------------------------
// 演示 1：负载均衡（MultiD 在两个 fdbm 之间按权重 1:3 分摊连接）
// ---------------------------------------------------------------------------
func loadBalance(datasource: MultiDatasource): Unit {
    println('---- 1. 负载均衡（multidbm_loadbalance = roundrobin,1,3）----')
    var hits1: Int64 = 0
    var hits2: Int64 = 0
    var i: Int64 = 1
    while (i <= 8) {
        let connection = datasource.connect()
        try {
            let node = probeInstance(connection)
            if (node == 'fdbm-1') {
                hits1 += 1
            } else {
                hits2 += 1
            }
            println('  connect #${i} -> ${node}')
        } finally {
            connection.close()
        }
        i += 1
    }
    println('  分布：fdbm-1=${hits1}  fdbm-2=${hits2}（权重 1:3）')
    check('load balance uses both fdbm instances', hits1 > 0 && hits2 > 0)
}

// ---------------------------------------------------------------------------
// 演示 2：数据分片（hash(id) → demo_0 / demo_1）
// ---------------------------------------------------------------------------
func sharding(connection: Connection): Unit {
    println('---- 2. 数据分片（fdbm_partition__t_order = demo,hash,id）----')
    // 参数化插入：? 占位符从 0 起索引；每条 INSERT 只落到分库键路由出的那一个物理库
    let insert = connection.prepareStatement(
        'insert into t_order (id, user_id, name) values (?, ?, ?)')
    try {
        var id: Int64 = 1
        while (id <= 6) {
            insert.set<Int64>(0, id)
            insert.set<Int64>(1, id * 10)
            insert.set<String>(2, 'order-${id}')
            checkInt('shard insert ${id}', insert.update().rowCount, 1)
            id += 1
        }
    } finally {
        insert.close()
    }

    // 不带分库键的 SELECT：广播合并 —— 服务端把两个物理库的结果集串成一个游标（行序 = 库序）
    let merged = connection.prepareStatement('select id, name from t_order')
    try {
        let result = merged.query()
        try {
            var rows: Int64 = 0
            while (result.next()) {
                rows += 1
                println('  合并行 ${rows}: id=${result.get<Int64>(0)}, name=${result.get<String>(1)}')
            }
            checkInt('merged select spans shards', rows, 6)
        } finally {
            result.close()
        }
    } finally {
        merged.close()
    }

    // 带分库键的点查：只路由到一个物理库
    checkText('point select by shard key', firstText(connection,
        'select name from t_order where id = 3') ?? '', 'order-3')

    // 参数化点查
    let point = connection.prepareStatement('select user_id from t_order where id = ?')
    try {
        point.set<Int64>(0, 5)
        let result = point.query()
        try {
            check('bound point select', result.next() && result.get<Int64>(0) == 50)
        } finally {
            result.close()
        }
    } finally {
        point.close()
    }

    // IN 多值：路由层按分库键拆分下推，各库只收自己的键
    checkInt('in-list across shards', execUpdate(connection,
        "update t_order set name = 'u' where id in (1, 2, 3, 4, 5, 6)"), 6)
}

// ---------------------------------------------------------------------------
// 演示 3：全局表（写广播到逻辑库全部物理库，读只取一个副本）
// ---------------------------------------------------------------------------
func globalTable(connection: Connection): Unit {
    println('---- 3. 全局表（fdbm_global__t_dict = demo，广播到 demo_0 与 demo_1）----')
    // 两个物理库各写一份 → rowCount = 2
    checkInt('global insert broadcast', execUpdate(connection,
        "insert into t_dict (code, label) values ('cn', 'China'), ('us', 'USA')"), 2)
    // 读只取一个副本（结果集 1 行）
    checkText('global read one replica', firstText(connection,
        "select label from t_dict where code = 'cn'") ?? '', 'China')
}

// ---------------------------------------------------------------------------
// 演示 4：读写分离（节点权重 n1 只写 / n2 只读 + postgres 账号级硬约束）
// ---------------------------------------------------------------------------
func readWriteSplit(connection: Connection): Unit {
    println('---- 4. 读写分离（fdbm_loadbalance_weight_n1 = w,1;r,0 / n2 = w,0;r,1）----')
    // 上面的写语句全部路由到 n1（账号 fdbm_w），SELECT 全部路由到 n2（账号 fdbm_r）。
    // fdbm_r 在物理库里只有 SELECT 权限：写语句若被错误路由到读节点，
    // postgres 会直接报 permission denied —— 演示能跑通本身就证明分离生效。
    println('  写 → n1（fdbm_w，可写）；读 → n2（fdbm_r，只读）')
    println('  物理库核对：../boot.sh check')
    check('read path works via read-only role',
        firstText(connection, "select label from t_dict where code = 'us'") ?? '', 'USA')
}

// ---------------------------------------------------------------------------
// 演示主流程（由 Initializer.start 调用；返回值即进程退出码）
// ---------------------------------------------------------------------------
func runDemo(): Int64 {
    println('==== fdbmdemo：f_dbd ↔ fdbm ×2 ↔ PostgreSQL（WSL Ubuntu 24.04） ====')
    println('客户端为动态库模块，由 fboot 启动（App dynamic 模式）')

    // ---------- f_dbd 初始化 ----------
    // 引用 multid 包的 multiDDriver()：触发 f_dbd.multid 的包级 static init，
    // 把 'multidbd' 注册进 std.database.sql.DriverManager；未注册时这里给出明确错误。
    let multid = multiDDriver()
    println('f_dbd 初始化完成：驱动 multidbd 已注册（version ${multid.version}）')

    // 客户端侧配置（f_config 三来源之一：Config.set；也可用环境变量
    // multidbm_loadbalance='roundrobin,1,3' 或 --multidbm_loadbalance=... 命令行）
    Config.set([('multidbm_loadbalance', 'roundrobin,1,3')])

    // ---------- 建立多节点数据源 ----------
    // URL：multidbm://[user:pass@]host:port[,...]/逻辑库；两个节点 = 两个 fdbm 实例
    let url = 'multidbm://fdbm@127.0.0.1:${FDBM1_PORT},fdbm@127.0.0.1:${FDBM2_PORT}/demo'
    let datasource = MultiDatasource(url)
    datasource.setOption('query_timeout', '30000')
    datasource.setOption('update_timeout', '30000')
    println('MultiDatasource 就绪：${url}')

    loadBalance(datasource)

    // ---------- 业务演示：DDL 广播 / 分片 / 全局表 / 读写分离 ----------
    let connection = datasource.connect()
    try {
        println('---- 0. DDL 广播（create/drop 到逻辑库 demo 的全部物理库）----')
        checkInt('ddl drop t_order', execUpdate(connection, 'drop table if exists t_order'), 0)
        checkInt('ddl drop t_dict', execUpdate(connection, 'drop table if exists t_dict'), 0)
        checkInt('ddl create t_order', execUpdate(connection,
            'create table t_order (id bigint primary key, user_id bigint, name varchar(64))'), 0)
        checkInt('ddl create t_dict', execUpdate(connection,
            'create table t_dict (code varchar(32) primary key, label varchar(64))'), 0)
        sharding(connection)
        globalTable(connection)
        readWriteSplit(connection)
    } finally {
        connection.close()
    }
    datasource.close()

    println('----')
    println('checks=${checks}, failures=${failures}')
    if (failures == 0) {
        println('全部通过。物理库分布用 ../boot.sh check 核对。')
        return 0
    }
    return 1
}
