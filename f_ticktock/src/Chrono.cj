/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_ticktock

import std.sync.Timer
import f_base.ZERO_TIMER

class Chrono {
    private var timer: Timer = ZERO_TIMER
    init() {}
    func start(emitter: Emitter) {
        let now = DateTime.now()
        timer = Timer.repeat(
            DateTime.of(
                year: now.year,
                month: now.month,
                dayOfMonth: now.dayOfMonth,
                hour: now.hour,
                minute: now.minute,
                second: now.second
            ) + Duration.second * 2 - DateTime.now(),
            Duration.second,
            {
                =>
                let now = DateTime.now()
                spawn {
                    emitter.emit(now)
                }
            }
        )
    }
    func shutdown() {
        timer.cancel()
    }
}
