/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
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
