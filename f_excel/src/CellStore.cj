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
package fountain::f_excel

import std.collection.ArrayList

private let CHUNK: Int64 = 4096

/**
 * 固定宽度的按位分块列。
 *
 * 用 `Array<Byte>` 手工打包，避免基础类型数组的槽位对齐开销：
 * 每格只占 `width` 字节，分块按 4096 个元素分配，没有 ArrayList 的 1.5x 扩容空洞。
 */
internal class ByteColumn {
    private let width: Int64
    private let chunks = ArrayList<Array<Byte>>()
    private var count: Int64 = 0

    init(width: Int64) {
        this.width = width
    }

    func size(): Int64 {
        this.count
    }

    private func ensure(index: Int64): Unit {
        while (Int64(this.chunks.size) <= index / CHUNK) {
            this.chunks.add(Array<Byte>(CHUNK * this.width, repeat: 0))
        }
    }

    func bitsAt(index: Int64): UInt64 {
        let chunk = this.chunks[index / CHUNK]
        let base = (index % CHUNK) * this.width
        var value: UInt64 = 0
        var i: Int64 = 0
        while (i < this.width) {
            value |= UInt64(chunk[base + i]) << (i * 8)
            i++
        }
        value
    }

    func setBits(index: Int64, bits: UInt64): Unit {
        this.ensure(index)
        let chunk = this.chunks[index / CHUNK]
        let base = (index % CHUNK) * this.width
        var i: Int64 = 0
        while (i < this.width) {
            chunk[base + i] = UInt8((bits >> (i * 8)) & 0xFF)
            i++
        }
    }

    func addBits(bits: UInt64): Unit {
        this.setBits(this.count, bits)
        this.count++
    }

    func insert(at: Int64, bits: UInt64): Unit {
        this.addBits(bits)
        var i = this.count - 1
        while (i > at) {
            this.setBits(i, this.bitsAt(i - 1))
            i--
        }
        this.setBits(at, bits)
    }

    func removeAt(at: Int64): Unit {
        var i = at
        while (i < this.count - 1) {
            this.setBits(i, this.bitsAt(i + 1))
            i++
        }
        this.count--
    }
}

/**
 * 列式单元格存储（M3-d 重构）。
 *
 * 布局：`row(UInt32)` + `col(UInt16)` + `payload(UInt32)` + 数值列(`Float64`)。
 * `payload` 最高位为 1 表示数值，低 31 位是数值列下标；否则指向 `others`。
 * 全数值表的内存约 **18 B/格**，低于 20 MB / 100 万格目标。
 */
internal class CellStore {
    private let rows = ByteColumn(4)
    private let cols = ByteColumn(2)
    private let payload = ByteColumn(4)
    private let numbers = ByteColumn(8)
    private let others = ArrayList<CellValue>()

    // 稠密矩形数值块：完全由 addNumber 按行优先填满时启用，只存 Float64。
    private var denseActive = false
    private var denseValues = ByteColumn(8)
    private var denseWidth: Int64 = 0
    private var denseRows: Int64 = 1
    private var denseRow: Int64 = 1
    private var denseCol: Int64 = 2

    func size(): Int64 {
        if (this.denseActive) {
            return this.denseValues.size()
        }
        this.rows.size()
    }

    private func resetDense(): Unit {
        this.denseActive = false
        this.denseValues = ByteColumn(8)
        this.denseWidth = 0
        this.denseRows = 1
        this.denseRow = 1
        this.denseCol = 2
    }

    /** 把稠密块摊回稀疏列（类型变化、随机写入、删除时调用）。 */
    private func flushDense(): Unit {
        if (!this.denseActive) {
            return
        }
        if (this.denseWidth == 0) {
            this.denseWidth = this.denseCol - 1
        }
        var index: Int64 = 0
        var row: Int64 = 1
        while (row <= this.denseRows) {
            let cols = if (row < this.denseRows) { this.denseWidth } else { this.denseCol - 1 }
            var col: Int64 = 1
            while (col <= cols) {
                let value = Float64.fromBits(this.denseValues.bitsAt(index))
                this.addNumberSparse(row, col, value)
                index++
                col++
            }
            row++
        }
        this.resetDense()
    }

    private func rowAt(index: Int64): Int64 {
        Int64(UInt32(this.rows.bitsAt(index)))
    }

    private func colAt(index: Int64): Int64 {
        Int64(UInt16(this.cols.bitsAt(index)))
    }

    private func compareAt(index: Int64, row: Int64, col: Int64): Int64 {
        let r = this.rowAt(index)
        if (r < row) {
            return -1
        }
        if (r > row) {
            return 1
        }
        let c = this.colAt(index)
        if (c < col) {
            return -1
        }
        if (c > col) {
            return 1
        }
        0
    }

    private func lowerBound(row: Int64, col: Int64): Int64 {
        var low: Int64 = 0
        var high = this.rows.size()
        while (low < high) {
            let mid = (low + high) / 2
            if (this.compareAt(mid, row, col) < 0) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        low
    }

    private func encode(value: CellValue): UInt32 {
        match (value) {
            case Number(v) =>
                this.numbers.addBits(v.toBits())
                UInt32(0x8000_0000) | UInt32(this.numbers.size() - 1)
            case _ =>
                this.others.add(value)
                UInt32(this.others.size - 1)
        }
    }

    private func decode(index: Int64): CellValue {
        let bits = UInt32(this.payload.bitsAt(index))
        if ((bits & 0x8000_0000) != 0) {
            let slot = Int64(bits & 0x7FFF_FFFF)
            CellValue.Number(Float64.fromBits(this.numbers.bitsAt(slot)))
        } else {
            this.others[Int64(bits)]
        }
    }

    func get(row: Int64, col: Int64): ?CellValue {
        if (this.denseActive) {
            if (this.denseWidth == 0) {
                this.flushDense()
            } else {
                if (row <= this.denseRows && col <= this.denseWidth) {
                    let index = (row - 1) * this.denseWidth + (col - 1)
                    if (index < this.denseValues.size()) {
                        return Some(CellValue.Number(Float64.fromBits(this.denseValues.bitsAt(index))))
                    }
                }
                return None<CellValue>
            }
        }
        let index = this.lowerBound(row, col)
        if (index < this.rows.size() && this.compareAt(index, row, col) == 0) {
            return Some(this.decode(index))
        }
        None<CellValue>
    }

    /** 数值快路径：不构造 `CellValue`；连续行优先写入会进入稠密块。 */
    func addNumber(row: Int64, col: Int64, value: Float64): Unit {
        if (this.denseActive) {
            if (row == this.denseRow && col == this.denseCol) {
                this.denseValues.addBits(value.toBits())
                this.denseCol++
                return
            }
            if (col == 1 && row == this.denseRow + 1) {
                let width = this.denseCol - 1
                if (this.denseWidth == 0) {
                    this.denseWidth = width
                } else if (width != this.denseWidth) {
                    this.flushDense()
                    this.addNumberSparse(row, col, value)
                    return
                }
                this.denseRow = row
                this.denseRows = row
                this.denseCol = 2
                this.denseValues.addBits(value.toBits())
                return
            }
            this.flushDense()
            this.addNumberSparse(row, col, value)
            return
        }
        if (this.rows.size() == 0 && row == 1 && col == 1) {
            this.denseActive = true
            this.denseRow = 1
            this.denseRows = 1
            this.denseCol = 2
            this.denseValues.addBits(value.toBits())
            return
        }
        this.addNumberSparse(row, col, value)
    }

    private func addNumberSparse(row: Int64, col: Int64, value: Float64): Unit {
        let index = this.lowerBound(row, col)
        if (index < this.rows.size() && this.compareAt(index, row, col) == 0) {
            let bits = UInt32(this.payload.bitsAt(index))
            if ((bits & 0x8000_0000) != 0) {
                this.numbers.setBits(Int64(bits & 0x7FFF_FFFF), value.toBits())
            } else {
                this.numbers.addBits(value.toBits())
                this.payload.setBits(index, UInt64(UInt32(0x8000_0000) | UInt32(this.numbers.size() - 1)))
            }
        } else {
            this.rows.insert(index, UInt64(UInt32(row)))
            this.cols.insert(index, UInt64(UInt16(col)))
            this.numbers.addBits(value.toBits())
            this.payload.insert(index, UInt64(UInt32(0x8000_0000) | UInt32(this.numbers.size() - 1)))
        }
    }

    func add(row: Int64, col: Int64, value: CellValue): Unit {
        match (value) {
            case Number(v) => this.addNumber(row, col, v)
            case _ =>
                this.flushDense()
                this.addOther(row, col, value)
        }
    }

    private func addOther(row: Int64, col: Int64, value: CellValue): Unit {
        let index = this.lowerBound(row, col)
        if (index < this.rows.size() && this.compareAt(index, row, col) == 0) {
            let bits = UInt32(this.payload.bitsAt(index))
            match (value) {
                case Number(v) => if ((bits & 0x8000_0000) != 0) {
                    this.numbers.setBits(Int64(bits & 0x7FFF_FFFF), v.toBits())
                } else {
                    this.payload.setBits(index, UInt64(this.encode(value)))
                }
                case _ => if ((bits & 0x8000_0000) == 0) {
                    this.others[Int64(bits)] = value
                } else {
                    this.payload.setBits(index, UInt64(this.encode(value)))
                }
            }
        } else {
            this.rows.insert(index, UInt64(UInt32(row)))
            this.cols.insert(index, UInt64(UInt16(col)))
            this.payload.insert(index, UInt64(this.encode(value)))
        }
    }

    func remove(row: Int64, col: Int64): Bool {
        this.flushDense()
        let index = this.lowerBound(row, col)
        if (index < this.rows.size() && this.compareAt(index, row, col) == 0) {
            this.rows.removeAt(index)
            this.cols.removeAt(index)
            this.payload.removeAt(index)
            return true
        }
        false
    }

    /** 一行的 `(col, value)`，按列升序。 */
    func rowEntries(row: Int64, maxCol: Int64): ArrayList<(Int64, CellValue)> {
        this.flushDense()
        let out = ArrayList<(Int64, CellValue)>()
        var index = this.lowerBound(row, 1)
        while (index < this.rows.size() && this.rowAt(index) == row) {
            let col = this.colAt(index)
            if (col > maxCol) {
                break
            }
            out.add((col, this.decode(index)))
            index++
        }
        out
    }
}
