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
package fountain::f_email.model

import std.env.getVariable
import std.fs.{Directory, File, Path, exists}
import std.random.Random

foreign {
    @When[os != "Windows"]
    func chmod(path: CString, mode: UInt32): Int32
}

/**
 * 临时文件暂存。
 *
 * 临时目录解析顺序（OHOS 上没有 `/tmp`，必须写死这条链）：
 *
 * 1. 调用方显式 `spoolDir`
 * 2. 环境变量 `TMPDIR`
 * 3. 系统临时目录（Windows 用 `TEMP`，其余 `/tmp`）
 * 4. 当前工作目录下的 `.fountain_tmp/`（自动创建）
 *
 * 文件名由内部随机生成，**绝不使用附件 `filename`**——附件名是不可信输入，
 * 参与路径就是路径穿越。创建后立即 `chmod 0600`。
 */
public class Spool {
    /** 创建一个可写的临时文件，返回路径（文件已存在且为空）。 */
    public static func createFile(spoolDir!: ?Path = None): Path {
        let directory = resolveDirectory(spoolDir: spoolDir)
        let random = Random()
        var attempt = 0
        while (attempt < 16) {
            let name = "_f_email_${random.nextUInt64().toString()}_${attempt}.tmp"
            let path = directory.join(name)
            if (exists(path)) {
                attempt += 1
                continue
            }
            try {
                let file = File.create(path)
                file.close()
                restrictPermissions(path.toString())
                return path
            } catch (_: Exception) {
                attempt += 1
            }
        }
        throw MimeException("无法创建附件临时文件，请显式指定 spoolDir")
    }

    /** 解析可用的临时目录；四处都不可用时抛 [MimeException]。 */
    public static func resolveDirectory(spoolDir!: ?Path = None): Path {
        if (let Some(dir) <- spoolDir) {
            ensureDirectory(dir)
            return dir
        }
        if (let Some(tmp) <- getVariable("TMPDIR")) {
            if (tmp.trimAscii().size > 0) {
                let dir = Path(tmp)
                if (ensureDirectory(dir)) {
                    return dir
                }
            }
        }
        let systemTemp = if (isWindows()) {
            getVariable("TEMP") ?? "C:\\Windows\\Temp"
        } else {
            "/tmp"
        }
        let tempDir = Path(systemTemp)
        if (ensureDirectory(tempDir)) {
            return tempDir
        }
        let fallback = Path(".fountain_tmp")
        if (ensureDirectory(fallback)) {
            return fallback
        }
        throw MimeException("无法创建附件临时文件，请显式指定 spoolDir")
    }

    private static func ensureDirectory(path: Path): Bool {
        if (exists(path)) {
            return true
        }
        try {
            Directory.create(path, recursive: true)
            true
        } catch (_: Exception) {
            false
        }
    }

    @When[os != "Windows"]
    private static func restrictPermissions(path: String): Unit {
        unsafe {
            let cpath = LibC.mallocCString(path)
            chmod(cpath, 0x180) // 0o600
            LibC.free(cpath)
        }
    }

    @When[os == "Windows"]
    private static func restrictPermissions(path: String): Unit {
        // Windows 没有 POSIX 权限位；临时文件默认落在用户临时目录，ACL 由系统继承。
    }

    @When[os == "Windows"]
    private static func isWindows(): Bool {
        true
    }

    @When[os != "Windows"]
    private static func isWindows(): Bool {
        false
    }
}
