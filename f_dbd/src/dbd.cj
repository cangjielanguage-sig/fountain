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
package fountain::f_dbd

import fountain::f_version.FountainVersion

/**
 * f_dbd 根包：驱动注册入口、版本信息与公开重导出（设计 §2）。
 *
 * 只 `import fountain::f_dbd.*` 即可拿到错误码、异常、单节点驱动与多节点数据源，无需深层包路径。
 */
public import fountain::f_dbd.common.*
public import fountain::f_dbd.driver.{DbdDriver, DbdUrl, dbdDriver}
public import fountain::f_dbd.multid.{MultiD, MultiDUrl, MultiDatasource}

/** f_dbd 模块版本（含 `fountain` 前缀）。 */
public func fdBDVersion(): String {
    FountainVersion
}
