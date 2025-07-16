/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_log

import stdx.log.LogLevel

public interface ExtendLogLevel {
    prop text: String
}

extend LogLevel <: ExtendLogLevel {
    public prop text: String {
        get() {
            if (this == FATAL) {
                '\u{1B}[1;5;43;91mFATAL\u{1B}[0m'
            } else if (this == ERROR) {
                '\u{1B}[1;91mERROR\u{1B}[0m'
            } else if (this == WARN) {
                '\u{1B}[1;91mWARN\u{1B}[0m'
            } else if (this == INFO) {
                '\u{1B}[92mINFO\u{1B}[0m'
            } else if (this == DEBUG) {
                '\u{1B}[34mDEBUG\u{1B}[0m'
            } else {
                this.toString()
            }
        }
    }
}
