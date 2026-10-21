# RxAgentManagement

Reusable macOS ACP registry, installation, persistence and CLI account management.
The same source and tests are provided as the `RxAgentManagement` product in the
sibling RxAgentSDK repository. Film Studio carries this source snapshot while its
main RxAgentSDK dependency remains pinned to the published 1.0.8 release.
When an SDK release includes this product, replace this local package reference
with that product and remove this snapshot. No sibling checkout is needed for CI.

Run `swift test --package-path Packages/RxAgentManagement`.
