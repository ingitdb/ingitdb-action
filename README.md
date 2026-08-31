# InGitDB repository validation action

This GitHub Action validates a complete InGitDB repository with an exact
`ingitdb/ingitdb-cli` release. It downloads only from the canonical CLI release,
verifies the published checksum before execution, installs into runner-temporary
storage, and emits stable terminal categories without writing to the checkout.

The first exercised runner is GitHub-hosted Ubuntu amd64. Consumers must pin
this action by a full 40-character commit SHA and grant only `contents: read`.
They must also supply an exact stable InGitDB CLI release tag:

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
  - uses: ingitdb/ingitdb-action@FULL_40_CHARACTER_COMMIT_SHA
    with:
      cli-version: v0.65.13
      database-root: .
```

The separately versioned reference workflow replaces the placeholder with the
first immutable action revision after that revision has landed. Never use
`main`, `v0`, or another moving action reference in a production workflow.
The first supported validation protocol is `ingitdb/ingitdb-cli` v0.65.13;
older releases are rejected before download because they do not guarantee
redacted diagnostics, panic-safe exit categories, or the action's status model.

Terminal categories are `success`, `invalid_data`, `configuration_error`,
`unsupported_runner`, `download_error`, `checksum_error`, `installation_error`,
`extraction_error`, `validator_error`, and `internal_error`. Invalid repository
data preserves the CLI's exit status `2`; other validator exits are propagated
unchanged.
