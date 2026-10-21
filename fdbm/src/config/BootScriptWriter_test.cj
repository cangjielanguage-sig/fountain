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

import std.fs.*
import std.random.Random
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_dbd.common.DbdErrorCode

/** Step 1.3 `BootScriptWriter`（设计 §3.5）：分块、排序、转义、原子写与幂等。 */
@Test
public class BootScriptWriterTest {

    @TestCase
    public func initRequiresAnExistingFile(): Unit {
        @Assert(fdbmCodeOf { BootScriptWriter('/tmp/definitely-not-here-${freeSuffix()}/boot.sh') },
            DbdErrorCode.CONFIG)
    }

    /** 只允许 `FdbmConfig` 白名单里的键；非法键不写 `Config`、不写脚本。 */
    @TestCase
    public func setValidatesWhitelist(): Unit {
        let file = scriptFile('#!/bin/bash\n')
        try {
            let writer = BootScriptWriter(file.toString())
            @Assert(fdbmCodeOf { writer.set('not_a_fdbm_key', '1') }, DbdErrorCode.CONFIG)
            writer.set('fdbm_port', '9000')
            @Assert(Config.getString('fdbm_port').getOrThrow(), '9000')
            writer.flush()
            @Assert(readFile(file).contains("export fdbm_port='9000'"), true)
        } finally {
            removeIfExists(file, recursive: true)
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 已有旧标记区块：整块替换，块外内容逐字节保留，旧标记/旧注释消失。 */
    @TestCase
    public func flushReplacesOldBlockAndKeepsTheRest(): Unit {
        let file = scriptFile('''
#!/bin/bash
# 手工头部

# ==== fdbm managed exports (do not reorder) ====
# 旧注释
export fdbm_port='8112'
export fdbm_db='old'

start() {
    echo hi
}
''')
        try {
            let writer = BootScriptWriter(file.toString())
            writer.set('fdbm_port', '9000')
            writer.flush()
            let text = readFile(file)
            @Assert(text.contains(BootScriptWriter.NEW_MARKER), true)
            @Assert(text.contains(BootScriptWriter.OLD_MARKER), false)
            @Assert(text.contains('旧注释'), false)
            @Assert(text.contains("export fdbm_port='9000'"), true)
            @Assert(text.contains("export fdbm_db='old'"), true)
            @Assert(text.contains('start() {'), true)
            @Assert(text.contains('echo hi'), true)
            @Assert(text.contains('# ---- 1. 服务与进程 ----'), true)
            @Assert(text.contains('# 监听端口'), true)
            @Assert(text.contains(BootScriptWriter.END_MARKER), true)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 没有标记区块 → 在末尾追加区块。 */
    @TestCase
    public func flushAppendsBlockWhenMissing(): Unit {
        let file = scriptFile('#!/bin/bash\necho start\n')
        try {
            let writer = BootScriptWriter(file.toString())
            writer.set('fdbm_cache', 'false')
            writer.flush()
            let text = readFile(file)
            @Assert(text.contains(BootScriptWriter.NEW_MARKER), true)
            @Assert(text.contains("export fdbm_cache='false'"), true)
            @Assert(text.contains('echo start'), true)
            @Assert(text.contains('# ---- 8. 分库缓存 ----'), true)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 同一组键值连续 `flush` 两次，字节一致。 */
    @TestCase
    public func flushIsIdempotent(): Unit {
        let file = scriptFile('#!/bin/bash\n')
        try {
            let writer = BootScriptWriter(file.toString())
            writer.set('fdbm_port', '9000')
            writer.set('fdbm_db', 'name0@h:1')
            writer.set('fdbm_partition__orders', 'order,hash,id')
            writer.flush()
            let first = readFile(file)
            writer.flush()
            @Assert(readFile(file), first)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 单引号转义：写入 `p'w` 后仍是同一个值（解析回读一致）。 */
    @TestCase
    public func escapesSingleQuotes(): Unit {
        let file = scriptFile('#!/bin/bash\n')
        try {
            let writer = BootScriptWriter(file.toString())
            writer.set('fdbm_db_password_name0', "p'w")
            writer.flush()
            let text = readFile(file)
            @Assert(text.contains("export fdbm_db_password_name0='p'\\''w'"), true)
            // 再 normalize 一次不应改变内容
            @Assert(BootScriptWriter(file.toString()).normalize(), false)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 启动整理：区块外的旧格式 `fdbm_*` 迁入区块、其余内容原样保留；第二次不再写回。 */
    @TestCase
    public func normalizeMigratesTopLevelExports(): Unit {
        let file = scriptFile('''
#!/bin/bash
export LD_LIBRARY_PATH=/opt/lib
export fdbm_port=8112
export fdbm_driverDir=/opt/driver
echo hello
''')
        try {
            let writer = BootScriptWriter(file.toString())
            @Assert(writer.normalize(), true)
            let text = readFile(file)
            @Assert(text.contains(BootScriptWriter.NEW_MARKER), true)
            @Assert(text.contains("export fdbm_port='8112'"), true)
            @Assert(text.contains("export fdbm_driverDir='/opt/driver'"), true)
            @Assert(text.contains('export LD_LIBRARY_PATH=/opt/lib'), true)
            @Assert(text.contains('echo hello'), true)
            // 第二次已经是规范形态
            @Assert(BootScriptWriter(file.toString()).normalize(), false)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 非白名单 `fdbm_*` 保留在区块外；区块内的非白名单键被丢弃。 */
    @TestCase
    public func nonWritableKeysAreKeptOutside(): Unit {
        let file = scriptFile('''
#!/bin/bash
export fdbm_unknown=1

# ==== fdbm managed exports (auto-generated; do not edit) ====
export fdbm_port='8112'
export fdbm_also_unknown=2
# ==== fdbm managed exports end ====
''')
        try {
            let writer = BootScriptWriter(file.toString())
            @Assert(writer.normalize(), true)
            let text = readFile(file)
            @Assert(text.contains('export fdbm_unknown=1'), true)
            @Assert(text.contains('fdbm_also_unknown'), false)
            @Assert(text.contains("export fdbm_port='8112'"), true)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 没有可整理的键 → 原样返回，不凭空造一个空区块。 */
    @TestCase
    public func normalizeLeavesUnrelatedFilesAlone(): Unit {
        let content = '#!/bin/bash\necho hi\n'
        let file = scriptFile(content)
        try {
            @Assert(BootScriptWriter(file.toString()).normalize(), false)
            @Assert(readFile(file), content)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** 整理失败不抛异常（返回 false），不阻塞启动。 */
    @TestCase
    public func normalizeFailureIsSwallowed(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let writer = BootScriptWriter(dir.toString())
            @Assert(writer.normalize(), false)
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    /** 保留可执行位。 */
    @TestCase
    public func flushKeepsExecutableBit(): Unit {
        let file = scriptFile('#!/bin/bash\n')
        try {
            @Assert(FileInfo(file).canExecute(), true)
            let writer = BootScriptWriter(file.toString())
            writer.set('fdbm_port', '9000')
            writer.flush()
            @Assert(FileInfo(file).canExecute(), true)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** G10：区块内外同键 → 区块内优先，区块外行被移除。 */
    @TestCase
    public func blockWinsOverOutsideDuplicates(): Unit {
        let file = scriptFile("""
#!/bin/bash
export fdbm_port=9100
# ==== fdbm managed exports (auto-generated; do not edit) ====
export fdbm_port='9000'
# ==== fdbm managed exports end ====
""")
        try {
            let writer = BootScriptWriter(file.toString())
            @Assert(writer.normalize(), true)
            let text = readFile(file)
            @Assert(text.contains("export fdbm_port='9000'"), true)
            @Assert(text.contains('9100'), false)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }

    /** G11：并发 set+flush 不报 CONFIG/ENOENT，最终脚本可再解析。 */
    @TestCase
    public func concurrentExportsAreSerialized(): Unit {
        let file = scriptFile('#!/bin/bash\n')
        try {
            let writer = BootScriptWriter(file.toString())
            let futures = ArrayList<Future<Unit>>()
            for (i in 0..2) {
                let fut = spawn {
                    for (_ in 0..100) {
                        writer.set('fdbm_port', '${9000 + i}')
                        writer.flush()
                    }
                }
                futures.add(fut)
            }
            for (fut in futures) {
                fut.get()
            }
            let text = readFile(file)
            @Assert(text.contains('export fdbm_port='), true)
        } finally {
            removeIfExists(file.toString().replace('/boot.sh', ''), recursive: true)
        }
    }
}

/** 建一个临时目录里的 `boot.sh`（默认带可执行位）。 */
func scriptFile(content: String): Path {
    let dir = Directory.createTemp('/tmp')
    let file = dir.join('boot.sh')
    File.writeTo(file, content.toArray())
    FileInfo(file).setExecutable(true)
    file
}

func readFile(path: Path): String {
    String.fromUtf8(File.readFrom(path))
}

func freeSuffix(): String {
    Random().nextUInt64().toString()
}
