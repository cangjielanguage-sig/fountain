package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.macros.*
import fountain::f_jit.base.DummyDiagnosticsSink

@JitBind
public open class ProbeBase {
    public var f: Int64 = 1
    public func m(): Int64 {
        10
    }
    public open func over(): Int64 {
        7
    }
}

@JitBind
public class ProbeDerived <: ProbeBase {
    public var d: Int64 = 2
    public func own(): Int64 {
        20
    }
    public override func over(): Int64 {
        99
    }
}

/**
 * X：父类公共成员并入子类描述符。
 *
 * 子类对象访问父类方法/字段必须能解析到；同名成员以子类为准。
 */
@Test
public class Inheritance_test {

    private static func compiler(): Compiler {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ProbeBase>()
        c.registerType<ProbeDerived>()
        c
    }

    /** 父类方法与字段在子类型上可见。 */
    @TestCase
    public func derivedSeesInheritedMembers(): Unit {
        let c = Inheritance_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: ProbeDerived => x.m() + x.f + x.d + x.own() }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Int64>([ProbeDerived()]), 33)
    }

    /** 覆盖优先：子类重写的 `over()` 必须命中子类实现。 */
    @TestCase
    public func overrideWins(): Unit {
        let c = Inheritance_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: ProbeDerived => x.over() }')
        @Assert(f.call<Int64>([ProbeDerived()]), 99)
    }
}
