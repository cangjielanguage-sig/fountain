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

public open class FuncInvocationTask <: TicktockTask {
    private var name_: String
    private var concurrentable_ = false
    private var once_ = false
    protected var function: () -> Unit

    public init(name: String, function: () -> Unit) {
        this.name_ = name
        this.function = function
    }

    public func setName(name: String) {
        this.name_ = name
    }
    public func setConcurrentable(concurrentable: Bool) {
        this.concurrentable_ = concurrentable
    }
    public func setOnce(once: Bool) {
        this.once_ = once
    }
    public func setFunction(function: () -> Unit) {
        this.function = function
    }
    public prop name: String {
        get() {
            name_
        }
    }
    public override prop concurrentable: Bool {
        get() {
            concurrentable_
        }
    }
    public override prop once: Bool {
        get() {
            once_
        }
    }
    public func execute(): Unit {
        function()
    }
}

public open class FuncInvocationCronTask <: FuncInvocationTask {
    private var cron_: String

    public init(name: String, cron: String, function: () -> Unit) {
        super(name, function)
        this.cron_ = cron
    }
    public prop cron: String {
        get() {
            cron_
        }
    }
}
