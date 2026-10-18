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
package fdbm_pg_driver_bundle

/**
 * 构建壳：本身不导出任何东西，只负责让 cjpm 把 `postgres_driver` 以动态库方式构建出来。
 *
 * 产物位于 `target/release/postgres_driver/libpostgres_driver.so`，由 `../run.sh` 复制到
 * fdbm 的 `driver/` 目录。
 */
public func bundleMarker(): String {
    'fdbm_pg_driver_bundle'
}
