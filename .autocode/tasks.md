# 当前任务

cjpm bench -j 1
error: 'incrFetch' is not a member of class 'AtomicInt64'
  ==> /mnt/d/docs/work/cangjie/projects/fountain/f_store/src/WAL.cj:59:28:
   | 
59 |         let seq = sequence.incrFetch()
   |                            ^^^^^^^^^ 
   | 
note: to use the following extension, you must import at least one of its inherited interfaces
   ==> (package fountain::f_concurrent)AtomicInteger.cj:284:1:

error: 'incrFetch' is not a member of class 'AtomicInt64'
  ==> /mnt/d/docs/work/cangjie/projects/fountain/f_store/src/WAL.cj:76:29:
   | 
76 |             if (appendCount.incrFetch() % syncInterval == 0) {
   |                             ^^^^^^^^^ 
   | 
note: to use the following extension, you must import at least one of its inherited interfaces
   ==> (package fountain::f_concurrent)AtomicInteger.cj:284:1:

error: 'incrFetch' is not a member of class 'AtomicInt64'
   ==> /mnt/d/docs/work/cangjie/projects/fountain/f_store/src/store_func.cj:113:42:
    | 
113 |     var sstIndex: Int64 = sstableFileSeq.incrFetch()
    |                                          ^^^^^^^^^ 
    | 
note: to use the following extension, you must import at least one of its inherited interfaces
   ==> (package fountain::f_concurrent)AtomicInteger.cj:284:1:

error: 'incrFetch' is not a member of class 'AtomicInt64'
   ==> /mnt/d/docs/work/cangjie/projects/fountain/f_store/src/store_func.cj:122:43:
    | 
122 |                 sstIndex = sstableFileSeq.incrFetch()
    |                                           ^^^^^^^^^ 
    | 
note: to use the following extension, you must import at least one of its inherited interfaces
   ==> (package fountain::f_concurrent)AtomicInteger.cj:284:1:

warning: unused import 'std.time.DateTime'
  ==> /mnt/d/docs/work/cangjie/projects/fountain/f_store/src/Store_bench.cj:23:1:
   | 
23 | import std.time.DateTime
   | ^^^^^^^^^^^^^^^^^^^^^^^^ unused import
   | 
   # note: this warning can be suppressed by setting the compiler option `-Woff unused`

4 errors generated, 4 errors printed.
1 warning generated, 1 warning printed.
Error: failed to compile package `fountain::f_store`, return code is 1
Error: please execute 'cjpm build -i -j1' successfully first
Error: cjpm bench failed