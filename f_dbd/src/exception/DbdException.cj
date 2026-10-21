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
package fountain::f_dbd.exception

/**
 * `DbdException` 的**重导出**（设计 §4）。
 *
 * 实现体在 `fountain::f_dbd.common`（`src/common/DbdException.cj`）—— `QueryResultImpl` /
 * `DbdInputStream` 都在 common 需要抛它，而它又需要 common 的 `DbdErrorCode` / `DbdErrorPayload`，
 * 留在本包会形成 `common → exception → common` 的包级循环（cjpm 拒绝构建）。
 *
 * 本包不复制类定义、不新增任何类型，只有这一行 `public import`；对调用方而言
 * `import fountain::f_dbd.exception.*` 拿到的类型与 `import fountain::f_dbd.common.*` **是同一个**。
 */
public import fountain::f_dbd.common.DbdException
