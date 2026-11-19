package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.macros.*
import fountain::f_jit.base.{DummyDiagnosticsSink, RegistrationException}

@JitBind
public interface ProbeNamed {
    func name(): String
}

@JitBind
public interface ProbeGreeter <: ProbeNamed {
    func greet(): String
}

@JitBind
public class ProbeGreeterImpl <: ProbeGreeter {
    public func name(): String {
        "impl"
    }
    public func greet(): String {
        "hello"
    }
}

/** 没有 @JitBind 的接口：注册期必须被拒绝。 */
public interface ProbeUnbound {
    func ping(): Int64
}

/**
 * X：接口支持（形参调用 / 父接口成员 / 返回类型）。
 *
 * 类成员的调用一直走 `@JitBind` 生成的强类型闭包（首参 14 → 强转 → 直调），不依赖反射；
 * 接口复用同一条路，因此反射「抽象方法不可 apply」的限制不再是问题。
 */
@Test
public class Interface_test {

    private static func compiler(): Compiler {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerInterface<ProbeNamed>()
        c.registerInterface<ProbeGreeter>()
        c.registerType<ProbeGreeterImpl>()
        c
    }

    /** 接口形参 + 自身方法：由机器码执行。 */
    @TestCase
    public func interfaceParamCallsOwnMethod(): Unit {
        let c = Interface_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ g: ProbeGreeter => g.greet() }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<String>([ProbeGreeterImpl()]), 'hello')
    }

    /** 父接口成员：只注册子接口，父接口方法仍可用。 */
    @TestCase
    public func parentInterfaceMemberIsVisible(): Unit {
        let c = Interface_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ g: ProbeGreeter => g.name() }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<String>([ProbeGreeterImpl()]), 'impl')
    }

    /** 接口作为返回类型：`call<I>` 不再报「T 不是可解包类型」。 */
    @TestCase
    public func interfaceAsReturnType(): Unit {
        let c = Interface_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ => ProbeGreeterImpl() }')
        @Assert(f.isJitBacked(), true)
        let g = f.call<ProbeGreeter>([])
        @Assert(g.greet(), 'hello')
        @Assert(g.name(), 'impl')
    }

    /** 未绑定接口：注册期拒绝，且消息指向 @JitBind。 */
    @TestCase
    public func unboundInterfaceIsRejected(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        var ok = false
        try {
            c.registerInterface<ProbeUnbound>()
        } catch (e: RegistrationException) {
            ok = true
        }
        @Assert(ok, true)
    }
}
