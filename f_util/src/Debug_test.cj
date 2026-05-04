package fountain::f_util

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Debug_test {
    @TestCase
    public func testDebug(): Unit {
        // Test PathPattern matching after compile
        let pp = PathPattern()
        pp.compile("/app/**/*.yaml")
        @Assert(pp.matches("/app/config/db/host.yaml"))
        @Assert(pp.matches("/app/host.yaml"))
        @Assert(pp.matches("/app/a/b/c/d/host.yaml"))
        @Assert(pp.matches("/app/.yaml"))
        @Assert(!pp.matches("/other/app/test.yaml"))
        @Assert(!pp.matches("/app/config/db/host.txt"))
    }
}
