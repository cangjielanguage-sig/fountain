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

import std.env.*

/** 服务配置：全部走环境变量，保持与 fboot/f_mvc 的部署方式一致 */
public class HydraConfig {
    public static const KEY_HEADER = 'X-Hydra-Key'

    public static func dataPath(): String {
        getVar('hydra_dataPath') ?? './data/fhydra'
    }

    /** 共享密钥；未设置时拒绝所有非本地调用（安全默认） */
    public static func secret(): String {
        getVar('hydra_secret') ?? ''
    }

    private static func getVar(name: String): ?String {
        match(getVariable(name)){
            case Some(value) =>
                if(value.isEmpty()){
                    None
                }else{
                    Some(value)
                }
            case None => None
        }
    }
}
