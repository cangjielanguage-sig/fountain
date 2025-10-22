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
package f_orm.wrap

/*
 * RequiresNew 和 NotSupported 会创建新连接，在这两个特性的作用范围内如果有其它传播特性判定还是以原连接是否创建了事务为依据。
 */
public enum Propagation {
    | Required //Support a current transaction, create a new one if none exists.
    | Supports //Support a current transaction, execute non-transactionally if none exists.
    | Mandatory //Support a current transaction, throw an exception if none exists.
    | RequiresNew //Create a new transaction, and suspend the current transaction if one exists.
    | Never //Execute non-transactionally, throw an exception if a transaction exists.
    | NotSupported //Execute non-transactionally, suspend the current transaction if one exists.
    | Nested //Execute within a nested transaction if a current transaction exists, behave like REQUIRED otherwise.
}
