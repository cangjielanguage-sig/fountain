// 差分测试层：同一单元跑 Interp / BackendX86_64 / BackendAArch64 并逐位对比（plan-m1 S0.2）。
// 约束：只放三引擎对照，禁止放单层语义断言（单层语义归各包 *_test.cj）。
package fountain::f_jit.test.diff
