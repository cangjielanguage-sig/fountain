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

public class Condition {
    private init(){}
    private static let _delimiter = ThreadLocal<String>()
    mut static prop delimiter: String {
        get() {
            _delimiter.get() ?? ''
        }
        set(value) {
            _delimiter.set(value)
        }
    }
    public func loop<I, T>(values: I, executor: SqlExecutor): LoopCondition<I, T> where I <: Iterable<T> {
        LoopCondition<I, T>(values, executor)
    }

    public func `set`(partial: () -> String): String {
        try {
            delimiter = ','
            ' `set` ${trim(prefix: ',', suffix: ',', partial: partial)} '
        } finally {
            delimiter = ''
        }
    }

    public func `where`(partial: () -> String): String {
        `where`('', partial)
    }
    public func `where`(delimiter: String, partial: () -> String): String {
        try{
            delimiter = delimiter
            let partial = trim(prefix: 'and|or', suffix: 'and|or', partial: partial)
            if(partial.isEmpty()){
                ''
            }else{
                ' `where` ${partial} '
            }
        }finally {
            delimiter = ''
        }
    }
    public static func trim(prefix!: String = '', suffix!: String = '', partial!: () -> String): String {
        '^\\s*(${prefix})\\s*|\\s*(${suffix})\\s*$'.regex(option: RegexOption().ignoreCase()).replaceAll(partial())
    }
}
