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
package fountain::fprobe.tui

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.collect.{Clock, FakeClock}
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}
import fountain::fprobe.supervisor.{NodeSource, NodeStateStore, PollLoop}

class RecordingPainter <: Painter {
    public var starts = 0
    public var draws = 0
    public var restores = 0

    public func start(): Unit {
        starts += 1
    }

    public func draw(_: RenderPlan): Unit {
        draws += 1
    }

    public func restore(): Unit {
        restores += 1
    }
}

class RecordingComponents <: SupervisorComponents {
    public var starts = 0
    public var stops = 0
    public var closes = 0
    private let onStop: () -> Unit

    init(onStop!: () -> Unit = {=> ()}) {
        this.onStop = onStop
    }

    public func start(): Unit {
        starts += 1
    }

    public func stop(): Unit {
        stops += 1
        onStop()
    }

    public func close(): Unit {
        closes += 1
    }
}

class RecordingHooks <: ExitHooks {
    public var gracefulCalls = 0
    private var callback: ?(() -> Unit) = None

    public func toExitGracefully(): Unit {
        gracefulCalls += 1
    }

    public func atExit(_: UInt16, callback: () -> Unit): Unit {
        this.callback = Some(callback)
    }

    public func fire(): Unit {
        match (callback) {
            case Some(action) => action()
            case None => ()
        }
    }
}

class FakeTtyDetector <: TtyDetector {
    private let value: Bool

    init(value: Bool) {
        this.value = value
    }

    public func isTty(): Bool {
        value
    }
}

class SingleSource <: NodeSource {
    public prop name: String {
        get() {
            "node-a"
        }
    }

    public func collect(): ProbeSnapshot {
        ProbeSnapshot("node-a", "h", 0, [ProbeAgentData("cpu", "h", "{}", 0, "")])
    }
}

func testApp(painter: Painter, hooks: ExitHooks, components: SupervisorComponents,
    log: (String) -> Unit): SupervisorApp {
    SupervisorApp(painter, FakeTtyDetector(false), hooks, components,
        log: log, keySource: None<KeySource>)
}

/** 13.1 / 13.2 / 13.3：resident 模式、信号退出、无 ANSI 输出。 */
@Test
public class SupervisorApp_test {
    @TestCase
    public func residentNeverStartsThePainter(): Unit {
        let painter = RecordingPainter()
        let components = RecordingComponents()
        let app = testApp(painter, RecordingHooks(), components, {_ => ()})

        @Assert(app.start(true), 0)
        @Assert(painter.starts, 0)
        @Assert(components.starts, 1)
        @Assert(app.running())
        app.shutdown()
        @Assert(!app.running())
    }

    @TestCase
    public func signalStopsPollLoopAndClosesConnections(): Unit {
        let clock: Clock = FakeClock(0)
        let loop = PollLoop([SingleSource()], NodeStateStore(), clock, 50, 2, {_ => ()}, {_ => ()})
        let components = RecordingComponents(onStop: {=> loop.stop()})
        let hooks = RecordingHooks()
        let app = testApp(RecordingPainter(), hooks, components, {_ => ()})

        @Assert(app.start(true), 0)
        @Assert(loop.isRunning())
        @Assert(hooks.gracefulCalls, 1)

        hooks.fire()

        @Assert(!app.running())
        @Assert(!loop.isRunning())
        @Assert(components.stops, 1)
        @Assert(components.closes, 1)
    }

    @TestCase
    public func residentLogsContainNoAnsiEscape(): Unit {
        let lines = ArrayList<String>()
        let painter = RecordingPainter()
        let app = testApp(painter, RecordingHooks(), RecordingComponents(),
            {line => lines.add(line)})

        @Assert(app.start(true), 0)
        app.shutdown()

        @Assert(!lines.isEmpty())
        for (line in lines) {
            @Assert(!line.contains("\u{1b}"))
        }
        @Assert(painter.starts, 0)
    }

    @TestCase
    public func nonResidentRejectsNonTty(): Unit {
        let painter = RecordingPainter()
        let lines = ArrayList<String>()
        let app = testApp(painter, RecordingHooks(), RecordingComponents(),
            {line => lines.add(line)})

        @Assert(app.start(false), 2)
        @Assert(painter.starts, 0)
        @Assert(!app.running())
        var hinted = false
        for (line in lines) {
            if (line.contains("resident")) {
                hinted = true
            }
        }
        @Assert(hinted)
    }
}
