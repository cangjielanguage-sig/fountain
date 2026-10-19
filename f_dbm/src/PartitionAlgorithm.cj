/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_dbm

/**
 * fdbm 分库算法扩展点。
 *
 * 实现必须稳定：同一 key 在任何节点、任何时刻都应映射到同一物理库。
 * key 的规范化（能无损解析为 Int64 就用 Int64，否则用 String）由 fdbm
 * 路由层在调用前完成，实现不应自行改变 key 的语义。
 */
public interface PartitionAlgorithm {
    /** 算法名，对应 fdbm_partition_algorithm 的配置值。 */
    prop name: String

    /** 返回物理数据库名；key 已由调用方规范化。 */
    func partition<K>(key: K): String
}
