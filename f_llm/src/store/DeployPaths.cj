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
package fountain::f_llm.store

import std.env.getCommand
import std.fs.{Path, canonicalize}

/**
 * 部署目录：可执行文件所在目录（若在 `bin/` 下则取其上一级）。
 *
 * 存储路径一律相对**部署目录**，而不是进程 CWD——服务被 systemd / 容器拉起时，
 * CWD 往往是 `/` 或不可控目录，相对路径会把数据写到意外位置。
 */
public class DeployPaths {
    private static var cached: ?String = None

    public static func root(): String {
        match(cached){
            case Some(value) => value
            case None =>
                var path = canonicalize(Path(getCommand()).parent)
                if(path.fileName == 'bin'){
                    path = path.parent
                }
                let value = path.toString()
                cached = Some(value)
                value
        }
    }

    /** 绝对路径原样返回；相对路径（含 `./`）拼到部署目录下 */
    public static func resolve(configured: String): String {
        if(configured.isEmpty()){
            return root()
        }
        if(configured.startsWith('/')){
            return configured
        }
        var relative = configured
        while(relative.startsWith('./')){
            relative = relative[2..relative.size]
        }
        if(relative.isEmpty()){
            return root()
        }
        '${root()}/${relative}'
    }
}
