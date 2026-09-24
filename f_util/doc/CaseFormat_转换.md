## CaseFormat 转换
```cj
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.LowerHyphen), "case-format")
```
