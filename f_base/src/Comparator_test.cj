package f_base

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Comparator_test {
    @TestCase
    public func test(): Unit {
        let cmp = Comparator<Int64>.compare<Int64>
        @Assert(Ordering.LT, cmp(1, 2))
        let comparator = Comparator<Int64>.create<Int64>()
        @Assert(Ordering.LT, cmp(1, 2))
    }
}
