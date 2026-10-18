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
package fountain::fdbm.config

import std.collection.{ArrayList, HashMap}
import std.fs.*
import fountain::f_config.Config
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_log.LoggerFactory
import fountain::fdbm.exception.FdbmException

/**
 * `boot.sh` 的 `export` 落盘（设计 §3.5）。
 *
 * - `flush()`：把 `set` 登记的键值合并进 managed 区块并重写（区块外逐字节保留）；
 * - `normalize()`：启动时整理脚本里已有的 `export fdbm_*`（迁移旧格式/旧标记），失败不阻塞启动。
 */
protected class BootScriptWriter {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.config.BootScriptWriter')

    static let NEW_MARKER = '# ==== fdbm managed exports (auto-generated; do not edit) ===='
    static let OLD_MARKER = '# ==== fdbm managed exports (do not reorder) ===='
    static let END_MARKER = '# ==== fdbm managed exports end ===='

    /** 固定键 → 注释（顺序即块内排序前的对照，不参与排序）。 */
    static let FIXED_COMMENTS = HashMap<String, String>([
        ('fdbm_port', '监听端口'),
        ('fdbm_bootScript', '启动脚本路径'),
        ('fdbm_driverDir', '物理驱动目录'),
        ('fdbm_customDir', '自定义扩展动态库目录'),
        ('fdbm_checkDuration', '心跳检查周期'),
        ('fdbm_unavailableChecked', '连续检查失败阈值'),
        ('fdbm_sessionSweepInterval', '断连会话巡检周期'),
        ('fdbm_shutdownTimeout', '优雅停止等待上限'),
        ('fdbm_db', '物理节点清单'),
        ('fdbm_partition_step', 'step 分库的步长'),
        ('fdbm_loadbalance', '节点选择算法：random | roundrobin'),
        ('fdbm_idmaker', 'ID 生成器与参数'),
        ('fdbm_sequenceDatabase', 'sequence 分配库'),
        ('fdbm_cache', '是否开启分库缓存'),
        ('fdbm_cache_expire', '缓存过期时间（空=永久）'),
        ('fdbm_cache_size', '缓存容量上限（0=不限制）'),
        ('fdbm_cachePath', 'f_store 落地目录')
    ])

    /** 连接池后缀 → 中文说明。 */
    static let POOL_COMMENTS = HashMap<String, String>([
        ('InitSize', '初始连接数'),
        ('MinSize', '最小连接数'),
        ('MaxSize', '最大连接数'),
        ('CheckOnCreation', '创建连接时是否检查连接有效性'),
        ('CheckOnBorrowing', '获取连接时是否检查连接有效性'),
        ('CheckOnReturning', '归还连接时是否检查连接有效性'),
        ('IdleTimeout', '连接闲置时间'),
        ('ConnectionLife', '连接存活时间'),
        ('CheckInterval', '连接有效性检查周期'),
        ('ConnectTimeout', '从连接池获取连接的超时时间'),
        ('MaxWaiting', '池耗尽的等待上限'),
        ('CheckSql', '检查连接有效性的 SQL')
    ])

    private let path: Path
    private let pending = HashMap<String, String>()

    public init(path: String) {
        let candidate = Path(path)
        if (candidate.toString().isEmpty() || !exists(candidate)) {
            throw FdbmException(DbdErrorCode.CONFIG, 'boot script \'${path}\' does not exist')
        }
        this.path = candidate
    }

    /** 校验白名单 → `Config.set`（当前进程立即生效）→ 登记待写。 */
    public func set(key: String, value: String): Unit {
        if (!isWritableKey(key)) {
            throw FdbmException(DbdErrorCode.CONFIG,
                'key \'${key}\' is not writable through the boot script')
        }
        Config.set([(key, value)])
        pending[key] = value
    }

    /** 重写 managed 区块：已有键保留，`set` 过的覆盖；区块外内容逐字节不变。 */
    public func flush(): Unit {
        let lines = readLines()
        let parsed = parseBlock(lines)
        let entries = HashMap<String, String>()
        for ((key, value) in parsed.entries) {
            if (isWritableKey(key)) {
                entries[key] = value
            } else {
                logger.warn('fdbm-managed block contains a non-writable key \'${key}\'; dropped')
            }
        }
        for ((key, value) in pending) {
            entries[key] = value
        }
        let block = renderBlock(entries)
        let merged = ArrayList<String>()
        var i: Int64 = 0
        while (i < parsed.start) {
            merged.add(lines[i])
            i += 1
        }
        for (line in block) {
            merged.add(line)
        }
        i = parsed.end
        while (i < lines.size) {
            merged.add(lines[i])
            i += 1
        }
        writeAtomically(joinLines(merged.toArray()))
    }

    /**
     * 启动时整理：把脚本里已有的顶层 `export fdbm_*` 收敛到规范区块。
     *
     * @return 是否写回（内容已规范 → `false`）
     */
    public func normalize(): Bool {
        try {
            let source = readText()
            let result = normalizeText(source)
            if (result == source) {
                return false
            }
            writeAtomically(result)
            true
        } catch (e: Exception) {
            logger.error('failed to normalize boot script \'${path}\': ${e.message}', e)
            false
        }
    }

    // ==================== 渲染 ====================

    private static func renderBlock(entries: HashMap<String, String>): Array<String> {
        let groups = Array<ArrayList<(String, String)>>(9) {_ => ArrayList<(String, String)>()}
        for ((key, value) in entries) {
            groups[groupOf(key)].add((key, value))
        }
        let lines = ArrayList<String>()
        lines.add(NEW_MARKER)
        var index: Int64 = 0
        while (index < groups.size) {
            let group = groups[index]
            if (!group.isEmpty()) {
                lines.add('')
                lines.add(blockTitle(index))
                lines.add(blockDescription(index))
                let sorted = sortedByKey(group.toArray())
                for ((key, value) in sorted) {
                    lines.add(commentOf(key))
                    lines.add('export ${key}=${shellQuote(value)}')
                }
            }
            index += 1
        }
        lines.add('')
        lines.add(END_MARKER)
        lines.toArray()
    }

    /** 分块：首个命中即归属（顺序见设计 §3.5）。 */
    private static func groupOf(key: String): Int64 {
        if (key == 'fdbm_port' || key == 'fdbm_bootScript' || key == 'fdbm_driverDir' ||
            key == 'fdbm_customDir' || key == 'fdbm_checkDuration' ||
            key == 'fdbm_unavailableChecked' || key == 'fdbm_sessionSweepInterval' ||
            key == 'fdbm_shutdownTimeout') {
            return 0
        }
        if (key == 'fdbm_db' || key.startsWith('fdbm_db_driver_') ||
            key.startsWith('fdbm_db_database_') || key.startsWith('fdbm_db_username_') ||
            key.startsWith('fdbm_db_password_')) {
            return 1
        }
        if (key.startsWith('fdbm_db_logicalDatabase_')) {
            return 2
        }
        if (key.startsWith('fdbm_databasePool')) {
            return 3
        }
        if (key == 'fdbm_loadbalance' || key.startsWith('fdbm_loadbalance_weight_')) {
            return 4
        }
        if (key == 'fdbm_partition_step' || key.startsWith('fdbm_partition__') ||
            key.startsWith('fdbm_partition_substr__') || key.startsWith('fdbm_global__')) {
            return 5
        }
        if (key == 'fdbm_idmaker' || key == 'fdbm_sequenceDatabase') {
            return 6
        }
        if (key == 'fdbm_cache' || key == 'fdbm_cache_expire' || key == 'fdbm_cache_size' ||
            key == 'fdbm_cachePath') {
            return 7
        }
        8
    }

    private static func blockTitle(group: Int64): String {
        match (group) {
            case 0 => '# ---- 1. 服务与进程 ----'
            case 1 => '# ---- 2. 物理节点与凭据 ----'
            case 2 => '# ---- 3. 逻辑库映射 ----'
            case 3 => '# ---- 4. 连接池 ----'
            case 4 => '# ---- 5. 负载均衡与读写权重 ----'
            case 5 => '# ---- 6. 分库与全局表 ----'
            case 6 => '# ---- 7. ID 生成 ----'
            case 7 => '# ---- 8. 分库缓存 ----'
            case _ => '# ---- 9. 其他 ----'
        }
    }

    private static func blockDescription(group: Int64): String {
        match (group) {
            case 0 => '# 监听端口、启动脚本、驱动/自定义扩展目录、心跳与优雅停止'
            case 1 => '# 节点清单，以及每节点的驱动、物理库与凭据'
            case 2 => '# 逻辑库 → 物理库列表；未配置的逻辑库包含全部物理库'
            case 3 => '# 每物理库一个池；未出现的键取默认值（见设计 §3.4）'
            case 4 => '# 节点选择算法与读写权重；库级优先于节点级'
            case 5 => '# 分库规则、子串参数与全局表；表名写在 __ 后'
            case 6 => '# 生成器类型/参数与 sequence 分配库'
            case 7 => '# 开关、过期、容量与 f_store 落地目录'
            case _ => '# 未归类的键（前向兼容）'
        }
    }

    private static func commentOf(key: String): String {
        if (let Some(text) <- FIXED_COMMENTS.get(key)) {
            return '# ${text}'
        }
        if (key.startsWith('fdbm_db_driver_')) {
            return '# 节点 ${key.removePrefix('fdbm_db_driver_')}：物理驱动名'
        }
        if (key.startsWith('fdbm_db_database_')) {
            return '# 节点 ${key.removePrefix('fdbm_db_database_')}：承载的物理库（逗号分隔）'
        }
        if (key.startsWith('fdbm_db_username_')) {
            return '# 节点 ${key.removePrefix('fdbm_db_username_')}：用户名'
        }
        if (key.startsWith('fdbm_db_password_')) {
            return '# 节点 ${key.removePrefix('fdbm_db_password_')}：密码（敏感，勿提交仓库）'
        }
        if (key.startsWith('fdbm_db_logicalDatabase_')) {
            return '# 逻辑库 ${key.removePrefix('fdbm_db_logicalDatabase_')} → 物理库列表'
        }
        if (key.startsWith('fdbm_databasePool')) {
            let suffix = key.removePrefix('fdbm_databasePool')
            if (let Some(text) <- POOL_COMMENTS.get(suffix)) {
                return '# 连接池：${text}'
            }
            return '# 连接池：${suffix}'
        }
        if (key.startsWith('fdbm_loadbalance_weight_')) {
            let suffix = key.removePrefix('fdbm_loadbalance_weight_')
            if (let Some(index) <- suffix.indexOf('__')) {
                return '# 节点 ${suffix[0..index]} / 库 ${suffix[index + 2..suffix.size]}：读写权重（优先于节点级）'
            }
            return '# 节点 ${suffix}：读写权重（w,1;r,2）'
        }
        if (key.startsWith('fdbm_partition_substr__')) {
            return '# 表 ${key.removePrefix('fdbm_partition_substr__')}：子串分库参数 <start>,<length>,<hash>'
        }
        if (key.startsWith('fdbm_partition__')) {
            return '# 表 ${key.removePrefix('fdbm_partition__')}：分库规则 <logical>,<algorithm>,<column>'
        }
        if (key.startsWith('fdbm_global__')) {
            return '# 表 ${key.removePrefix('fdbm_global__')}：全局表所在逻辑库'
        }
        '# 未归类：${key}'
    }

    // ==================== 解析与写回 ====================

    /** 解析结果：区块在原文件中的行区间 `[start, end)`，以及区块内的键值。 */
    private static func parseBlock(lines: Array<String>): BlockParse {
        var marker: Int64 = -1
        var i: Int64 = 0
        while (i < lines.size) {
            let trimmed = lines[i].trimAscii()
            if (trimmed == NEW_MARKER || trimmed == OLD_MARKER) {
                marker = i
                break
            }
            i += 1
        }
        if (marker < 0) {
            return BlockParse(lines.size, lines.size, HashMap<String, String>())
        }
        let entries = HashMap<String, String>()
        var end = marker + 1
        while (end < lines.size) {
            let trimmed = lines[end].trimAscii()
            if (trimmed == END_MARKER) {
                end += 1
                break
            }
            if (trimmed.isEmpty() || trimmed.startsWith('#')) {
                end += 1
                continue
            }
            if (trimmed.startsWith('export ')) {
                if (let Some((key, value)) <- parseExport(trimmed)) {
                    entries[key] = value
                }
                end += 1
                continue
            }
            break
        }
        BlockParse(marker, end, entries)
    }

    /** `export key=value` → `(key, unquoted)`；不是 `fdbm_*` 或格式不对 → `None`。 */
    private static func parseExport(line: String): ?(String, String) {
        let body = line.removePrefix('export ').trimAscii()
        let eq = match (body.indexOf('=')) {
            case Some(index) => index
            case None => return None<(String, String)>
        }
        let key = body[0..eq].trimAscii()
        if (!key.startsWith('fdbm_')) {
            return None<(String, String)>
        }
        let value = body[eq + 1..body.size].trimAscii()
        Some((key, shellUnquote(value)))
    }

    private func normalizeText(source: String): String {
        let lines = source.split('\n')
        let parsed = parseBlock(lines)
        let entries = HashMap<String, String>()
        for ((key, value) in parsed.entries) {
            if (isWritableKey(key)) {
                entries[key] = value
            } else {
                logger.warn('fdbm-managed block contains a non-writable key \'${key}\'; dropped')
            }
        }
        // 区块外的旧格式顶层 export：一次性迁入
        let outside = ArrayList<String>()
        var i: Int64 = 0
        while (i < lines.size) {
            if (i >= parsed.start && i < parsed.end) {
                i += 1
                continue
            }
            let trimmed = lines[i].trimAscii()
            if (trimmed.startsWith('export fdbm_') && !lines[i].startsWith(' ')) {
                if (let Some((key, value)) <- parseExport(trimmed)) {
                    if (isWritableKey(key)) {
                        entries[key] = value
                        i += 1
                        continue
                    }
                }
            }
            outside.add(lines[i])
            i += 1
        }
        // 没有区块、也没有任何可整理的键：原样返回（不凭空插入空区块）
        if (parsed.start == parsed.end && entries.isEmpty()) {
            return source
        }
        let block = renderBlock(entries)
        let result = ArrayList<String>()
        if (parsed.start < parsed.end) {
            var inserted = false
            i = 0
            while (i < outside.size) {
                if (!inserted && i == parsed.start) {
                    for (line in block) {
                        result.add(line)
                    }
                    inserted = true
                }
                result.add(outside[i])
                i += 1
            }
            if (!inserted) {
                for (line in block) {
                    result.add(line)
                }
            }
        } else {
            // 没有区块：插到第一条顶层 export fdbm_* 之前；没有则追加到末尾
            var position = outside.size
            i = 0
            while (i < outside.size) {
                if (outside[i].startsWith('export fdbm_')) {
                    position = i
                    break
                }
                i += 1
            }
            i = 0
            while (i < position) {
                result.add(outside[i])
                i += 1
            }
            for (line in block) {
                result.add(line)
            }
            while (i < outside.size) {
                result.add(outside[i])
                i += 1
            }
        }
        joinLines(result.toArray())
    }

    private func readText(): String {
        String.fromUtf8(File.readFrom(path))
    }

    private func readLines(): Array<String> {
        readText().split('\n')
    }

    /**
     * 临时文件 + rename 原子替换；保留可执行位。
     *
     * 注意：不保留完整 mode 位（std.fs 只暴露可读/可写/可执行三组），与设计 §3.5 的
     * "复制原文件权限位"存在偏差，已在详细设计登记。
     */
    private func writeAtomically(content: String): Unit {
        let target = path.toString()
        let temp = '${target}.tmp'
        try {
            File.writeTo(Path(temp), content.toArray())
            if (FileInfo(path).canExecute()) {
                FileInfo(Path(temp)).setExecutable(true)
            }
            rename(Path(temp), to: path, overwrite: true)
        } catch (e: Exception) {
            try {
                if (exists(Path(temp))) {
                    remove(Path(temp))
                }
            } catch (_: Exception) {
                ()
            }
            throw FdbmException(DbdErrorCode.CONFIG,
                'failed to write boot script \'${target}\': ${e.message}', e)
        }
    }

    // ==================== 工具 ====================

    private static func isWritableKey(key: String): Bool {
        if (FIXED_COMMENTS.get(key).isSome()) {
            return true
        }
        key.startsWith('fdbm_db_driver_') || key.startsWith('fdbm_db_database_') ||
            key.startsWith('fdbm_db_username_') || key.startsWith('fdbm_db_password_') ||
            key.startsWith('fdbm_db_logicalDatabase_') || key.startsWith('fdbm_databasePool') ||
            key.startsWith('fdbm_loadbalance_weight_') || key.startsWith('fdbm_partition__') ||
            key.startsWith('fdbm_partition_substr__') || key.startsWith('fdbm_global__')
    }

    /** shell 单引号转义：`'` → `'\''`。 */
    private static func shellQuote(value: String): String {
        let escaped = StringBuilder()
        for (rune in value.toRuneArray()) {
            if (UInt32(rune) == 0x27) {
                escaped.append("'\\''")
            } else {
                escaped.append(rune)
            }
        }
        "'" + escaped.toString() + "'"
    }

    /** 去掉一层单引号并还原 `'\''`。 */
    private static func shellUnquote(value: String): String {
        if (value.size >= 2 && value.startsWith('\'') && value.endsWith('\'')) {
            return value[1..value.size - 1].replace("'\\''", "'")
        }
        value
    }

    private static func joinLines(lines: Array<String>): String {
        let builder = StringBuilder()
        var i: Int64 = 0
        while (i < lines.size) {
            builder.append(lines[i])
            if (i < lines.size - 1) {
                builder.append('\n')
            }
            i += 1
        }
        builder.toString()
    }

    private static func sortedByKey(entries: Array<(String, String)>): Array<(String, String)> {
        let copy = entries
        var i: Int64 = 1
        while (i < copy.size) {
            let current = copy[i]
            var j = i - 1
            while (j >= 0 && copy[j][0] > current[0]) {
                copy[j + 1] = copy[j]
                j -= 1
            }
            copy[j + 1] = current
            i += 1
        }
        copy
    }
}

/** `parseBlock` 的返回值。 */
class BlockParse {
    let start: Int64
    let end: Int64
    let entries: HashMap<String, String>

    init(start: Int64, end: Int64, entries: HashMap<String, String>) {
        this.start = start
        this.end = end
        this.entries = entries
    }
}
