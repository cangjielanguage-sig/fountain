/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_log

import std.env
import std.sync.AtomicReference
import std.process.Process
import std.time.DateTime
import stdx.log.LogLevel

import f_io.DummyOutputStream

public class LoggerWrapper <: AbstractLogger {
    private var facade: AtomicReference<LoggerAppenderFacade>

    public LoggerWrapper(name: String) {
        super(name, LogLevel.ALL, LogPattern.default, DummyOutputStream.instance)
        this.facade = AtomicReference<LoggerAppenderFacade>(LoggerConfig.createFacade(name))
        env.atExit {this.facade.load().close()}
    }

    public func logLevelEnabled(level: LogLevel): Bool {
        facade.load().logLevelEnabled(level)
    }

    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        facade.load().append(level, message, now, ex)
    }
    public func refresh() {
        var replaced = false
        while(!replaced) {
            try {
                let (facade, replaced_) = super.doLock{
                    let new = LoggerConfig.createFacade(name)
                    let old = this.facade.load()
                    if (this.facade.compareAndSwap(old, new)) {
                        (old, true)
                    } else {
                        (new, true)
                    }
                }
                replaced = replaced_
                facade.close()
            }catch(e: Exception){
                e.printStackTrace()
            }
        }
    }
}
