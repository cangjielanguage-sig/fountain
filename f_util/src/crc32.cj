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

// 1. 导入可能需要的标准库模块
import std.io.*
import std.convert.*
import fountain::f_base.*

// 2. 定义CRC32查表法的主要结构体（使用struct模拟命名空间）

// 2.1 定义算法常量
// 标准CRC-32（IEEE 802.3）使用的多项式，也是zlib、gzip、PNG等采用的值
private const POLYNOMIAL: UInt32 = 0xEDB88320
// 初始值和最终异或值
private const INIT_VALUE: UInt32 = 0xFFFFFFFF
private const FINAL_XOR_VALUE: UInt32 = 0xFFFFFFFF

// 2.2 预计算表（查找表）
// 使用Array<UInt32>类型，长度为256，所有元素初始化为0
private let table: Array<UInt32> = {
    =>
        let table = Array<UInt32>(256, repeat: 0)
        // 在结构体加载时自动执行，用于生成table的内容
        for (i in 0..256) {
            var crc: UInt32 = UInt32(i)
            // 对每个可能的字节值进行8次迭代
            for (_ in 0..8) {
                // 判断最低位是否为1
                if ((crc & 1) != 0) {
                    // 如果是1，则右移一位后与多项式进行异或运算
                    crc = (crc >> 1) ^ POLYNOMIAL
                } else {
                    // 如果为0，则直接右移一位
                    crc = crc >> 1
                }
            }
            table[i] = crc
        }
        table
}()

// 2.4 核心计算函数（增量式：帧校验需要“边写边算 / 边读边算”，不能等整块拼齐）
/** 初始化 CRC 寄存器。 */
@Frozen
public func crc32Init(): UInt32 {
    INIT_VALUE
}
/** 继续累计一段字节。 */
@Frozen
public func crc32Update(crc: UInt32, data: Array<Byte>): UInt32 {
    var c = crc
    for (byte in data) {
        let index: UInt32 = (c ^ UInt32(byte)) & 0xFFu32
        c = (c >> 8) ^ table[Int64(index)]
    }
    c
}
/** 收尾：与 FINAL_XOR_VALUE 异或。 */
@Frozen
public func crc32Finish(crc: UInt32): UInt32 {
    crc ^ FINAL_XOR_VALUE
}
/** 一次算完整段（等价 init → update → finish）。 */
@Frozen
public func crc32(data: Array<Byte>): UInt32 {
    crc32Finish(crc32Update(crc32Init(), data))
}
@Frozen
public func crc32(data: String): UInt32 {
    return crc32(data.unsafeBytes())
}
@Frozen
public func crc32<T>(s: T): UInt32 where T <: ToString {
    crc32(s.toString().unsafeBytes())
}