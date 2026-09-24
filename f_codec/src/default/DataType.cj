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
package fountain::f_codec.default

/**
```md
| ------------------- | ------------ |
| None(n)             | 0\|0000      |
| 字符串(s)           | 1\|0001      |
| Bool(b)             | 2\|0010      |
| 整数(i)             | 3\|0011      |
| 浮点数(f)           | 4\|0100      |
| BigInt(bi1\|bi2)    | 5\|0101      |
| Decimal(r1)         | 6\|0110      |
| Decimal(r2)         | 7\|0111      |
| Duration(d1)        | 8\|1000      |
| Duration(d2)        | 9\|1001      |
| DateTime(t1)        | 10\|1010     |
| DateTime(t2)        | 11\|1011     |
| list\|array\|set(l) | 12\|1100     |
| map(m)              | 13\|1101     |
| object(o)           | 14\|1110     |
| inputstream(is)     | 15\|1111     |
```
*/
public enum DataType <: ToString {
    | NONE
    | STRING
    | BOOL
    | INT
    | FLOAT
    | BIGINT
    | DECIMAL1
    | DECIMAL2
    | DURATION1
    | DURATION2
    | DATETIME1
    | DATETIME2
    | COLLECTION
    | MAP
    | OBJECT
    | INPUTSTREAM
    
    public func toString(): String {
        match(this){
            case NONE => 'NONE'
            case STRING => 'STRING'
            case BOOL => 'BOOL'
            case INT => 'INT'
            case FLOAT => 'FLOAT'
            case BIGINT => 'BIGINT'
            case DECIMAL1 => 'DECIMAL1'
            case DECIMAL2 => 'DECIMAL2'
            case DURATION1 => 'DURATION1'
            case DURATION2 => 'DURATION2'
            case DATETIME1 => 'DATETIME1'
            case DATETIME2 => 'DATETIME2'
            case COLLECTION => 'COLLECTION'
            case MAP => 'MAP'
            case OBJECT => 'OBJECT'
            case INPUTSTREAM => 'INPUTSTREAM'
        }
    }
    public prop value: UInt8 {
        get(){
            match(this){
                case NONE => 0
                case STRING => 0x10
                case BOOL => 0x20
                case INT => 0x30
                case FLOAT => 0x40
                case BIGINT => 0x50
                case DECIMAL1 => 0x60
                case DECIMAL2 => 0x70
                case DURATION1 => 0x80
                case DURATION2 => 0x90
                case DATETIME1 => 0xa0
                case DATETIME2 => 0xb0
                case COLLECTION => 0xc0
                case MAP => 0xd0
                case OBJECT => 0xe0
                case INPUTSTREAM => 0xf0
            }
        }
    }
    public prop lowValue: UInt8 {
        get(){
            value >> 4
        }
    }
    public static func convert(byte: Byte): DataType {
        match(byte){
            case 0x00 => NONE
            case 0x10 => STRING
            case 0x20 => BOOL
            case 0x30 => INT
            case 0x40 => FLOAT
            case 0x50 => BIGINT
            case 0x60 => DECIMAL1
            case 0x70 => DECIMAL2
            case 0x80 => DURATION1
            case 0x90 => DURATION2
            case 0xa0 => DATETIME1
            case 0xb0 => DATETIME2
            case 0xc0 => COLLECTION
            case 0xd0 => MAP
            case 0xe0 => OBJECT
            case 0xf0 => INPUTSTREAM
            case _ => throw CodecException('Invalid data type: ${byte}')
        }
    }
}