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
package fountain::f_dbd.common

import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * 细粒度错误码（设计 §3.8）。
 *
 * fdbm 的所有失败路径都回 `Message.error(id, data: DbdErrorPayload(...))`，
 * 禁止不回包（否则客户端只能等超时）。
 *
 * 仓颉的 `enum` 构造器**不支持** `| INTERNAL = 0` 这样的整数字面量赋值
 * （`开发指南/enum.md`：构造器只能带参数、不能带默认值），故线上数值由 `value` 属性给出，
 * 反向解析由 `parse` 给出 —— 数值表与设计 §3.8 一一对应。
 */
public enum DbdErrorCode <: Equatable<DbdErrorCode> & ToString {
    | INTERNAL             // 0  服务端内部错误
    | PROTOCOL             // 1  协议/编解码/载荷判别失败
    | SQL_SYNTAX           // 2  SQL 解析失败
    | UNSUPPORTED_SQL      // 3  语法可解析但本版本不支持
    | ROUTE_FAILED         // 4  找不到物理库/分区路由失败
    | PARTITION_CONFIG     // 5  分区配置错误
    | NO_DRIVER            // 6  物理库驱动缺失
    | CURSOR_STATE         // 7  游标状态错误
    | TX_STATE             // 8  事务状态错误
    | DB_ERROR             // 9  物理库返回的错误（SqlException 透传）
    | TIMEOUT              // 10 请求超时
    | CONFIG               // 11 配置错误
    | CACHE                // 12 缓存相关错误
    | IO                   // 13 网络/IO 错误
    | ID_GENERATOR         // 14 ID 生成失败
    | CONVERSION           // 15 值转换失败：参数类型不支持、单元格与要求类型不符、NULL 强取

    /** 线上数值（= 设计 §3.8 表中的编号）。 */
    public prop value: Int64 {
        get() {
            match (this) {
                case INTERNAL => 0
                case PROTOCOL => 1
                case SQL_SYNTAX => 2
                case UNSUPPORTED_SQL => 3
                case ROUTE_FAILED => 4
                case PARTITION_CONFIG => 5
                case NO_DRIVER => 6
                case CURSOR_STATE => 7
                case TX_STATE => 8
                case DB_ERROR => 9
                case TIMEOUT => 10
                case CONFIG => 11
                case CACHE => 12
                case IO => 13
                case ID_GENERATOR => 14
                case CONVERSION => 15
            }
        }
    }

    public func toString(): String {
        match (this) {
            case INTERNAL => 'INTERNAL'
            case PROTOCOL => 'PROTOCOL'
            case SQL_SYNTAX => 'SQL_SYNTAX'
            case UNSUPPORTED_SQL => 'UNSUPPORTED_SQL'
            case ROUTE_FAILED => 'ROUTE_FAILED'
            case PARTITION_CONFIG => 'PARTITION_CONFIG'
            case NO_DRIVER => 'NO_DRIVER'
            case CURSOR_STATE => 'CURSOR_STATE'
            case TX_STATE => 'TX_STATE'
            case DB_ERROR => 'DB_ERROR'
            case TIMEOUT => 'TIMEOUT'
            case CONFIG => 'CONFIG'
            case CACHE => 'CACHE'
            case IO => 'IO'
            case ID_GENERATOR => 'ID_GENERATOR'
            case CONVERSION => 'CONVERSION'
        }
    }

    public operator func ==(other: DbdErrorCode): Bool {
        this.value == other.value
    }

    /** 反向解析；未知值（含越界）→ `INTERNAL`。 */
    public static func parse(value: Int64): DbdErrorCode {
        match (value) {
            case 0 => INTERNAL
            case 1 => PROTOCOL
            case 2 => SQL_SYNTAX
            case 3 => UNSUPPORTED_SQL
            case 4 => ROUTE_FAILED
            case 5 => PARTITION_CONFIG
            case 6 => NO_DRIVER
            case 7 => CURSOR_STATE
            case 8 => TX_STATE
            case 9 => DB_ERROR
            case 10 => TIMEOUT
            case 11 => CONFIG
            case 12 => CACHE
            case 13 => IO
            case 14 => ID_GENERATOR
            case 15 => CONVERSION
            case _ => INTERNAL
        }
    }
}

@DataAssist[fields props]
public class DbdErrorPayload {
    private var code: Int64 = 0        // DbdErrorCode.value
    private var sqlState: String = ''
    private var message: String = ''

    public init() {}

    public init(code: DbdErrorCode, message: String, sqlState!: String = '') {
        this.code = code.value
        this.message = message
        this.sqlState = sqlState
    }

    /** 回读为 `DbdErrorCode`；未知值（含越界）→ `INTERNAL`。 */
    public func errorCode(): DbdErrorCode {
        DbdErrorCode.parse(code)
    }
}
