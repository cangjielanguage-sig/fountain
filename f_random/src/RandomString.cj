/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_random

import std.collection.ArrayList

import crypto.crypto.SecureRandom

/*
   Char 到 UInt32 的转换使用 UInt32(e) 的方式，其中 e 是一个 Char 类型的表达式， UInt32(e)
   的结果是 e 的 Unicode scalar value 对应的 UInt32 类型的整数值。
   整数类型到 Char 的转换使用 Char(num) 的方式，其中 num 的类型可以是任意的整数类型，且仅当
   num 的值落在 [0x0000, 0xD7FF] 或 [0xE000, 0x10FFFF] （即 Unicode scalar value）中时，返
   回对应的 Unicode scalar value 表示的字符，否则，编译报错（编译时可确定 num 的值）或运行时抛
   异常。
 */
public class RandomString {
    private static func concat(arrays: Array<Array<Rune>>){
        let list = ArrayList<Rune>()
        for(array in arrays){
            list.appendAll(array)
        }
        list.toArray()
    }
    private static let LOWER_LETTERS = "abcdefghijklmnopqrstuvwxyz".toRuneArray()
    private static let UPPER_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".toRuneArray()
    private static let ALL_LETTERS = concat(UPPER_LETTERS, LOWER_LETTERS)
    private static let NUMBERS = "0123456789".toRuneArray()
    private static let LOWER_LETTERS_AND_NUMBERS = concat(LOWER_LETTERS, NUMBERS)
    private static let UPPER_LETTERS_AND_NUMBERS = concat(UPPER_LETTERS, NUMBERS)
    private static let ALL_LETTERS_AND_NUMBERS = concat(ALL_LETTERS, NUMBERS)
    private static let ALL_PRINTABLE_ASCIIS = concat(ALL_LETTERS_AND_NUMBERS, "`~!@#$%^&*()-_=+[{]}\\|'\";:/?.>,<".toRuneArray())
    // private static let ALL_CHARS = [[UInt32(0x0000), UInt32(0xD7FF)], [UInt32(0xE000), UInt32(0x10FFFF)]]

    public RandomString(private let rand!: SecureRandom = ThreadLocalRandom.current) {}
    public init(priv: Bool) {
        this(rand: SecureRandom(priv: priv))
    }

    public func randomAscii(count: Int64) {
        var builder = StringBuilder()
        var i = 0
        while (i < count) {
            builder.append(Rune(rand.nextUInt32(128)))
            i++
        }
        return builder.toString()
    }
    public func randomAscii(min: Int64, max: Int64) {
        randomAscii(rand.nextInt64(min, max, closed: true))
    }
    public func random(count: Int64, source: String) {
        random(count, source.toRuneArray())
    }
    public func random(count: Int64, source: Array<Rune>) {
        var builder = StringBuilder()
        var i = 0
        while (i < count) {
            builder.append(source[rand.nextInt64(source.size)])
            i++
        }
        return builder.toString()
    }
    public func random(min: Int64, max: Int64, source: String) {
        random(rand.nextInt64(min, max, closed: true), source)
    }
    public func randomLowerLetters(count: Int64) {
        random(count, LOWER_LETTERS)
    }
    public func randomLowerLetters(min: Int64, max: Int64) {
        randomLowerLetters(rand.nextInt64(min, max))
    }

    public func randomUpperLetters(count: Int64) {
        random(count, UPPER_LETTERS)
    }
    public func randomUpperLetters(min: Int64, max: Int64) {
        randomUpperLetters(rand.nextInt64(min, max))
    }

    public func randomAllLetters(count: Int64) {
        random(count, ALL_LETTERS)
    }
    public func randomAllLetters(min: Int64, max: Int64) {
        randomLowerLetters(rand.nextInt64(min, max))
    }

    public func randomNumbers(count: Int64) {
        random(count, NUMBERS)
    }
    public func randomNumbers(min: Int64, max: Int64) {
        randomNumbers(rand.nextInt64(min, max))
    }

    public func randomLowerLettersNumbers(count: Int64) {
        random(count, LOWER_LETTERS_AND_NUMBERS)
    }
    public func randomLowerLettersNumbers(min: Int64, max: Int64) {
        randomLowerLettersNumbers(rand.nextInt64(min, max))
    }
    public func randomUpperLettersNumbers(count: Int64) {
        random(count, LOWER_LETTERS_AND_NUMBERS)
    }
    public func randomUpperLettersNumbers(min: Int64, max: Int64) {
        randomLowerLettersNumbers(rand.nextInt64(min, max))
    }
    public func randomLettersNumbers(count: Int64) {
        random(count, ALL_LETTERS_AND_NUMBERS)
    }
    public func randomLettersNumbers(min: Int64, max: Int64) {
        randomLowerLettersNumbers(rand.nextInt64(min, max))
    }
    public func randomPrintableAsciis(count: Int64) {
        random(count, ALL_PRINTABLE_ASCIIS)
    }
    public func randomPrintableAsciis(min: Int64, max: Int64) {
        randomPrintableAsciis(rand.nextInt64(min, max))
    }
    public func randomAllChars(count: Int64) {
        var builder = StringBuilder()
        var i = 0
        while (i < count) {
            builder.append(Rune(rand.nextUInt32(0, 0x10FFFF, closed: true)))
            i++
        }
        return builder.toString()
    }
    public func randomAllChars(min: Int64, max: Int64) {
        randomAllChars(rand.nextInt64(min, max))
    }
}
