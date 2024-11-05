/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public interface ExtendRune {
    operator func -(c: Rune): UInt32
    operator func +(n: Int8): Rune
    operator func -(n: Int8): Rune
    operator func +(n: UInt8): Rune
    operator func -(n: UInt8): Rune
    operator func +(n: Int16): Rune
    operator func -(n: Int16): Rune
    operator func +(n: UInt16): Rune
    operator func -(n: UInt16): Rune
    operator func +(n: Int32): Rune
    operator func -(n: Int32): Rune
    operator func +(n: UInt32): Rune
    operator func -(n: UInt32): Rune
    operator func +(n: Int64): Rune
    operator func -(n: Int64): Rune
    operator func +(n: UInt64): Rune
    operator func -(n: UInt64): Rune
}

extend Rune <: ExtendRune {
    public operator func +(n: Int8): Rune {
        if (n > 0) {
            this + UInt32(n)
        } else {
            this - UInt32(-n)
        }
    }
    public operator func -(n: Int8): Rune {
        if (n > 0) {
            this - UInt32(n)
        } else {
            this + UInt32(-n)
        }
    }
    public operator func +(n: UInt8): Rune {
        this + UInt32(n)
    }
    public operator func -(n: UInt8): Rune {
        this - UInt32(n)
    }
    public operator func +(n: Int16): Rune {
        if (n > 0) {
            this + UInt32(n)
        } else {
            this - UInt32(-n)
        }
    }
    public operator func -(n: Int16): Rune {
        if (n > 0) {
            this - UInt32(n)
        } else {
            this + UInt32(-n)
        }
    }
    public operator func +(n: UInt16): Rune {
        this + UInt32(n)
    }
    public operator func -(n: UInt16): Rune {
        this - UInt32(n)
    }
    public operator func +(n: UInt32): Rune {
        Rune(UInt32(this) + n)
    }
    public operator func -(n: UInt32): Rune {
        Rune(UInt32(this) - n)
    }
    public operator func -(c: Rune): UInt32 {
        UInt32(this) - UInt32(c)
    }
    public operator func +(n: Int64): Rune {
        if (n > 0) {
            this + UInt32(n)
        } else {
            this - UInt32(-n)
        }
    }
    public operator func -(n: Int64): Rune {
        if (n > 0) {
            this - UInt32(n)
        } else {
            this + UInt32(-n)
        }
    }
    public operator func +(n: UInt64): Rune {
        this + UInt32(n)
    }
    public operator func -(n: UInt64): Rune {
        this - UInt32(n)
    }
    public operator func +(n: Int32): Rune {
        if (n > 0) {
            this + UInt32(n)
        } else {
            this - UInt32(-n)
        }
    }
    public operator func -(n: Int32): Rune {
        if (n > 0) {
            this - UInt32(n)
        } else {
            this + UInt32(-n)
        }
    }
}

