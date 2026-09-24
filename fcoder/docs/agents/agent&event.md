|agent     |接收事件         |发送事件   |
|:---------|:---------------|:----------|
|Supervisor|Start,SpecReview,CodeReivew |Requirements,FeasibilityReview,FeasibilityReport,RequirementReview,RequirementSpec,PreliminaryReview,PreliminarySpec,DetailReview,DetailSpec,Code&Spec,CodeCommitation,ToCommit|
|Analyst   |Requirements    |FeasibilityPreview|
|FeasibilityReviewer|FeasibilityPreview|SpecReview|
|ProductManager|FeasibilityReport,RequirementReview|RequirementPreview|
|RequirementReviewer|RequirementsPreview|SpecReview|
|SystemArchitect|RequirementSpec,PreliminaryReview|PreliminaryPreview|
|PreliminaryReviewer|PreliminaryPreview|SpecReview|
|ApplicationArchitect|PreliminarySpec,DetailReview|DetailPreview|
|DetailReviewer|DetailPreview|SpecReview|
|SeniorEngineer|DetailSpec|Decl|
|Developer|Decl,Code&Spec|Impl&Spec|
|CodePreviewer|Impl&Spec|CodeReview|
|CodeCommiitter|ToCommit|End|