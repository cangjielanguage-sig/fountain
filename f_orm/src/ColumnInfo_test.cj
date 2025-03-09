/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

public class ColumnInfoTest <: ColumnInfo {
    public ColumnInfoTest(private let n: String, private let tn: String) {
    }
    public prop name: String {
        get() {
            n
        }
    }

    // 列 类 型 名 称 ， 如 果 在 SqlDataType 中 定 义 ， 返 回 SqlDataType.toString(), 如 果 未 在SqlDataType 中 定 义 ， 由 数 据 库 驱 动 定 义
    public prop typeName: String {
        get() {
            tn
        }
    }

    // 列 值 的 最 大 显 示 长 度 ， 如 果 无 限 制 ， 则 应 该 返 回 Int64.Max （ 仍 然 受 数 据 库 的 限 制 ）
    public prop displaySize: Int64 {
        get() {
            10
        }
    }

    /**
     * 获 取 列 值 大 小 。
     * 对 于 数 值 数 据 ， 这 是 最 大 精 度 。
     * 对 于 字 符 数 据 ， 这 是 以 字 符 为 单 位 的 长 度 。
     * 对 于 日 期 时 间 数 据 类 型 ， 这 是 字 符 串 表 示 形 式 的 最 大 字 符 长 度 。
     * 对 于 二 进 制 数 据 ， 这 是 以 字 节 为 单 位 的 长 度 。
     * 对 于 RowID 数 据 类 型 ， 这 是 以 字 节 为 单 位 的 长 度 。
     * 对 于 列 大 小 不 适 用 的 数 据 类 型 ， 返 回 0。
     */
    public prop length: Int64 {
        get() {
            10
        }
    }

    // 列 值 的 小 数 长 度 ， 如 果 无 小 数 部 分 ， 返 回 0
    public prop scale: Int64 {
        get() {
            0
        }
    }

    // 列 值 是 否 允 许 数 据 库 Null 值
    public prop nullable: Bool {
        get() {
            false
        }
    }
}
