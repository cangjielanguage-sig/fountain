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
package fountain::f_util

// 文件名: crc64_ecma.cj

// 导入标准库包
import std.io.*
import std.convert.*
import fountain::f_base.*

// 定义 CRC64-ECMA-182 计算器
// --- 1. 定义算法常量 ---
// ECMA-182 多项式
private const POLYNOMIAL: UInt64 = 0x42F0E1EBA9EA3693
// 初始值与最终异或值，ECMA-182 标准均为 0
private const INIT_VALUE: UInt64 = 0x0000000000000000
private const FINAL_XOR_VALUE: UInt64 = 0x0000000000000000

// --- 2. 预计算查找表 ---
// 使用 Array<UInt64> 类型，长度为 256，所有元素初始化为 0
private let table: Array<UInt64> = {
    =>
        let table = Array<UInt64>(256, repeat: 0)
        // ECMA-182 是**非反射**算法：寄存器左移，取高 8 位作索引
        for (i in 0..256) {
            var crc: UInt64 = UInt64(i) << 56
            for (_ in 0..8) {
                if ((crc & 0x8000000000000000) != 0) {
                    crc = (crc << 1) ^ POLYNOMIAL
                } else {
                    crc = crc << 1
                }
            }
            table[i] = crc
        }
        table
}()

// --- 4. 核心计算函数 ---
// 功能：计算字节数组的 CRC64 值
// 参数 data：需要计算校验和的字节数组
// 返回值：计算得到的 64 位 CRC 校验值
@Frozen
public func crc64(data: Array<Byte>): UInt64 {
    var crc: UInt64 = INIT_VALUE

    for (byte in data) {
        // 非反射：索引 = (寄存器高 8 位 ^ 字节值) & 0xFF
        let index: Int64 = Int64(((crc >> 56) ^ UInt64(byte)) & 0xFF)

        // 1. 寄存器左移 8 位；2. 与查表值异或
        crc = (crc << 8) ^ table[index]
    }

    // 最终结果与 FINAL_XOR_VALUE 进行异或
    return crc ^ FINAL_XOR_VALUE
}
@Frozen
public func crc64(data: String): UInt64 {
    return crc64(data.unsafeBytes())
}
@Frozen
public func crc64<T>(s: T): UInt64 where T <: ToString {
    crc64(s.toString().unsafeBytes())
}