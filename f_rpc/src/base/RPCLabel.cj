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
package fountain::f_rpc.base

/**
 * Stub的参数是服务版本号，编译时@RPCClient宏从cjpm build的工作路径下的cjpm.toml找到被编译项目的版本号作为Stub的构造参数。
 * 如果两个版本号的前两位一样，认为两个版本是兼容的，则两个Stub被判定为相等。
 */
public enum RPCLabel <: Equatable<RPCLabel> {
    | Stub(String)
    | Skeleton

    public operator func ==(other: RPCLabel): Bool {
        match((this, other)){
            case (Stub(x), Stub(y)) => 
                let v1 = x.split('.')
                let v2 = y.split('.')
                v1[0] == v2[0] && v1[1] == v2[1]
            case (Skeleton, Skeleton) => true
            case _ => false
        }
    }
}