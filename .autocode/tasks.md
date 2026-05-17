✅ cd fmq && cjpm test — 130/130 passed (2026-05-17)

fix: DefaultCodec 解码空 Array<Byte> 时创建 Array(0) 再 read() ，
     Cangjie std.io 抛 "The buffer cannot be empty"。
     FIX: size==0 时直接返回 Array<Byte>().toData() 跳过 read。
