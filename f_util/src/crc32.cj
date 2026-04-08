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

// 2.4 核心计算函数：计算字节数组的CRC32值
// 参数 data: 需要计算校验和的字节数组
// 返回值: 计算得到的32位CRC校验值（UInt32类型）
public func crc32(data: Array<Byte>): UInt32 {
    // 初始化CRC寄存器
    var crc: UInt32 = INIT_VALUE

    // 遍历输入数据的每一个字节
    for (byte in data) {
        // 将byte转换为UInt32，并与当前CRC寄存器的低8位进行异或，作为查表索引
        // 仓颉语言的数组索引可能要求整数类型，这里进行类型转换
        let index: UInt32 = (crc ^ UInt32(byte)) & 0xFFu32

        // 更新CRC寄存器
        // 步骤：
        // 1. 将当前CRC寄存器右移8位
        // 2. 查表得到索引对应的预计算值
        // 3. 将移位后的CRC值与查表得到的值进行异或
        crc = (crc >> 8) ^ table[Int64(index)]
    }

    // 最终结果与FINAL_XOR_VALUE进行异或，完成计算
    return crc ^ FINAL_XOR_VALUE
}

public func crc32(data: String): UInt32 {
    return crc32(data.unsafeBytes())
}
