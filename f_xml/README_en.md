# f_xml

Generic **XML 1.0** parser and generator. **Not tied to any business format**: RSS / Atom, SVG,
SOAP, POM, Android layouts, OOXML or any configuration file that conforms to XML 1.0 can use the
same capabilities. The module knows nothing about business tags; it only explains XML.

> Design and trade-offs: [`doc/f_xml模块设计.md`](doc/f_xml模块设计.md) (Chinese).

## Dependencies

```
f_xml
├── f_base               StringGenerator (UTF-8 byte accumulation, zero-transcode unsafeBytes)
├── charset4cj           Non-UTF-8 encodings (GBK / UTF-16 / UTF-32 …)
└── std.io / std.fs      Strings and byte streams
```

- **No dependency on `f_io`**: the only accepted data source is `std.io.InputStream`; any
  interface implementation (including buffers) can be passed in.
- Fully self-implemented, without consulting any existing XML implementation; the only behavioral
  reference is XML 1.0 and Namespaces in XML 1.0.

## Capabilities (by milestone)

| Milestone | Scope |
|---|---|
| M1 | Push / pull / single-callback parsers, DOM, writer, DTD internal entities with spill policy, security limits |
| M2 | XPath 1.0 subset with namespace prefixes |
| M3 | XML 1.1, C14N (inclusive 1.0/1.1 + exclusive 1.0) |

## Status

The module skeleton exists; implementation proceeds through OpenSpec changes, with specs and
records under `doc/spec/`.
