---
format: https://specscore.md/feature-specification
status: Draft
---

# Feature: Repository Validation Action

> [SpecScore.**Studio**](https://specscore.studio): | [Explore](https://specscore.studio/app/github.com/ingitdb/ingitdb-action/spec/features/repository-validation-action?op=explore) | [Edit](https://specscore.studio/app/github.com/ingitdb/ingitdb-action/spec/features/repository-validation-action?op=edit) | [Ask question](https://specscore.studio/app/github.com/ingitdb/ingitdb-action/spec/features/repository-validation-action?op=ask) | [Request change](https://specscore.studio/app/github.com/ingitdb/ingitdb-action/spec/features/repository-validation-action?op=request-change) |
**Status:** Draft
**Date:** 2026-08-31
**Owner:** alex
**Source Ideas:** —
**Supersedes:** —

## Summary

A reproducible GitHub Action that validates a complete InGitDB repository with a pinned, verified InGitDB CLI.

## Problem

The current action resolves a mutable `latest` release from the obsolete
`ingitdb/ingitdb-go` release location, downloads an archive without verifying a
checksum, extracts it into the repository workspace, and interpolates an
arbitrary argument string into a shell command. A workflow can therefore run a
different validator without changing its source, execute an unverified binary,
or appear to validate successfully while using a release channel that no
longer owns the CLI.

OpenVaultDB-generated repositories need an immutable, least-privilege check
whose conclusion means exactly one thing: a named repository root was validated
by a named `ingitdb/ingitdb-cli` release and the action exited according to that
validator's data findings.

## Behavior

### End-to-end journey

1. A repository workflow checks out an exact Git commit and invokes this action
   by a full action commit SHA.
2. The workflow supplies an exact `ingitdb/ingitdb-cli` release version and the
   database root, normally `.`.
3. The action downloads the matching platform archive and published checksum
   into runner-temporary storage, verifies the archive, and invokes
   `ingitdb validate` against the requested root.
4. Valid data produces a successful check and records the validator identity.
   Invalid data produces a failing check with findings. Unsupported runners,
   missing checksums, download failures, and CLI crashes fail distinctly and
   MUST NOT be reported as invalid repository data. Unexpected action failures
   also emit a stable infrastructure category.

### Reproducible tool acquisition

#### REQ: exact-cli-version-required

The action MUST use an exact `ingitdb/ingitdb-cli` release version supplied by
the workflow or pinned in the reviewed action revision. It MUST NOT resolve
`latest`, a moving branch, or an unqualified release channel at runtime.

#### REQ: canonical-cli-release-source

CLI archives and checksums MUST be downloaded from releases owned by
`ingitdb/ingitdb-cli`. The action MUST NOT download the CLI from
`ingitdb/ingitdb-go` or another implementation repository.

#### REQ: checksum-before-execution

The downloaded archive MUST be verified against the checksum artifact published
for the exact release before extraction or execution. Missing, malformed, or
mismatched checksums MUST fail the action.

#### REQ: temporary-tool-directory

The archive and executable MUST be placed in runner-temporary storage outside
the checked-out repository. Running validation MUST leave the Git working tree
unchanged.

#### REQ: safe-archive-extraction

Before extraction, the action MUST reject absolute, parent-traversing,
unexpected, duplicate-executable, symlink, and hardlink archive members. It
MUST extract only one regular `ingitdb` executable inside runner-temporary
storage and MUST NOT follow an archive member outside that directory.

#### REQ: supported-runner-matrix

The action MUST explicitly map supported operating-system and architecture
pairs to release artifact names and MUST fail with an actionable message for an
unsupported pair. GitHub-hosted Ubuntu on amd64 is the required first platform;
additional pairs require an exercised test fixture.

### Narrow validation contract

#### REQ: validate-command-only

The action MUST expose a repository-validation contract rather than interpolate
an arbitrary shell argument string. Structured inputs MAY select the database
root and supported validation options, but MUST NOT permit command substitution
or execution of an arbitrary InGitDB subcommand.

#### REQ: explicit-database-root

The action MUST accept a database-root input, default it to `.`, canonicalize it
within `GITHUB_WORKSPACE`, and refuse traversal outside the checked-out
repository. It MUST invoke validation from or against that exact root so a
root-level `.ingitdb/` database is validated as a whole.

#### REQ: complete-repository-validation

The default invocation MUST validate the complete configured InGitDB database,
including every root collection, nested collection, record, schema constraint,
and cross-collection reference supported by the selected CLI release. Changed-
range optimization MAY be added later only if it preserves one authoritative
whole-database verdict where the caller requests it.

#### REQ: validator-exit-status-is-authoritative

The action MUST propagate the InGitDB validator's exit status. It MUST NOT infer
success from process completion, log text, checkout status, or a GitHub workflow
watch command.

#### REQ: distinguish-data-and-infrastructure-failure

The action MUST make data-validation failure distinguishable from installation,
network, checksum, unsupported-runner, configuration, or validator-crash
failure through stable output/status metadata and actionable log summaries.

#### REQ: no-repository-write-permission

The documented generated workflow MUST require only `contents: read`; the
action MUST NOT call the GitHub contents API, commit, push, upload repository
data to a third-party service, or require a write-capable token.

### Consumer pinning and evidence

#### REQ: immutable-action-consumption

Documentation and examples MUST instruct consumers to invoke the action by full
Git commit SHA. A human-readable comment MAY name the corresponding qualified
`ingitdb/ingitdb-action` release, but a moving branch such as `main` MUST NOT be
the generated production example.

#### REQ: validation-identity-output

Every run MUST expose or print the action revision, exact
`ingitdb/ingitdb-cli` version, resolved database root, validated commit SHA,
start/completion times, and terminal category without including record values.

#### REQ: findings-are-actionable-without-record-leakage

Invalid data MUST report collection, constraint, and repository-relative file
or record identity where supplied by InGitDB. Logs and outputs MUST NOT print
complete record bodies or secret-bearing field values merely to explain a
finding.

#### REQ: reference-workflow-covers-external-edits

The repository MUST provide a reference workflow that runs on pull requests,
pushes to the protected/default branch, and manual dispatch, with explicit
`contents: read` permission and concurrency that does not cancel the only check
for a newer commit.

## Acceptance Criteria

### AC: exact-cli-release-validates-clean-repository (verifies REQ:exact-cli-version-required, REQ:canonical-cli-release-source, REQ:checksum-before-execution, REQ:temporary-tool-directory, REQ:explicit-database-root, REQ:complete-repository-validation, REQ:validator-exit-status-is-authoritative, REQ:validation-identity-output)

**Given** a clean fixture repository and an exact published `ingitdb/ingitdb-cli` version
**When** the action runs on a supported GitHub-hosted Ubuntu runner
**Then** it verifies the matching archive checksum outside the worktree, validates the root database successfully, leaves the worktree clean, and reports the CLI version and validated commit SHA

### AC: mutable-latest-is-impossible (verifies REQ:exact-cli-version-required, REQ:canonical-cli-release-source)

**Given** a workflow omits an exact supported CLI version and the action revision does not pin one
**When** the action starts
**Then** it fails configuration validation without querying a latest-release endpoint or downloading from `ingitdb/ingitdb-go`

### AC: checksum-mismatch-never-executes-binary (verifies REQ:checksum-before-execution)

**Given** a downloaded archive does not match the exact release checksum
**When** acquisition completes
**Then** the action fails before extraction/execution and identifies checksum verification as the terminal category

### AC: unsafe-archive-member-never-escapes-temporary-storage (verifies REQ:safe-archive-extraction, REQ:temporary-tool-directory)

**Given** a checksum-valid fixture archive contains a symlink, hardlink,
absolute path, parent traversal, unexpected member, or duplicate executable
**When** acquisition completes
**Then** the action fails in the extraction category before executing the CLI
or writing outside runner-temporary storage

### AC: unsupported-runner-fails-actionably (verifies REQ:supported-runner-matrix, REQ:distinguish-data-and-infrastructure-failure)

**Given** the action runs on an operating-system/architecture pair outside its tested matrix
**When** platform detection completes
**Then** the action fails with the unsupported pair and does not describe the repository as invalid

### AC: arbitrary-shell-input-cannot-execute (verifies REQ:validate-command-only, REQ:explicit-database-root)

**Given** an input contains shell metacharacters, command substitution, or a path outside `GITHUB_WORKSPACE`
**When** the action validates its structured inputs
**Then** it rejects the input and executes neither the injected command nor validation outside the checkout

### AC: invalid-record-fails-authoritatively (verifies REQ:complete-repository-validation, REQ:validator-exit-status-is-authoritative, REQ:findings-are-actionable-without-record-leakage)

**Given** a fixture contains a record that violates its declared InGitDB schema
**When** the complete database is validated
**Then** the action fails from the validator's non-zero status, identifies the collection/constraint/file without dumping the record body, and categorizes the result as invalid data

### AC: broken-cross-collection-reference-fails (verifies REQ:complete-repository-validation)

**Given** two collections or Space namespaces contain a broken declared reference
**When** the repository root is validated
**Then** the action fails even when the directly changed record belongs to only one namespace

### AC: installer-outage-is-not-invalid-data (verifies REQ:distinguish-data-and-infrastructure-failure)

**Given** release download, checksum retrieval, or validator startup fails
**When** the action terminates
**Then** the check fails closed but its terminal category is infrastructure/configuration rather than invalid repository data

### AC: action-does-not-mutate-or-write-repository (verifies REQ:temporary-tool-directory, REQ:no-repository-write-permission)

**Given** the workflow grants only `contents: read`
**When** validation succeeds or fails
**Then** the Git worktree remains clean and the action has attempted no contents write, commit, or push

### AC: production-example-is-immutable (verifies REQ:immutable-action-consumption, REQ:reference-workflow-covers-external-edits)

**Given** a user copies the documented production workflow
**When** its triggers and action reference are inspected
**Then** it covers pull request, default-branch push, and manual dispatch; grants only contents read; and invokes `ingitdb/ingitdb-action` by full commit SHA rather than `main`

## Dependencies

- `ingitdb/ingitdb-cli` must publish platform archives and machine-verifiable
  checksums for each supported exact release.
- The selected CLI release owns validation semantics and exit-code categories;
  this action faithfully transports them and does not reimplement validation.

## Implementation

- [`action.yml`](../../../action.yml) defines the structured composite-action
  contract and stable outputs.
- [`scripts/validate.sh`](../../../scripts/validate.sh) validates inputs,
  acquires and verifies the CLI, contains extraction, runs full-root validation,
  suppresses untrusted workflow-command interpretation, and emits terminal
  metadata.
- [`test/validate_test.sh`](../../../test/validate_test.sh) exercises success,
  invalid data, input injection, unsupported runners, acquisition/checksum,
  unsafe archives, path escape, output safety, and validator-runtime failures.
- [`test/fixtures/valid`](../../../test/fixtures/valid) and
  [`test/fixtures/invalid-cross-collection`](../../../test/fixtures/invalid-cross-collection)
  exercise the published CLI against both a complete valid repository and a
  broken foreign-key reference between collections.
- [`.github/workflows/test.yml`](../../../.github/workflows/test.yml) runs the
  contract tests and both real-repository fixtures on the exercised
  GitHub-hosted Ubuntu runner.

## Open Questions

- Should the action initially support macOS and Windows runners, or deliberately
  ship only the exercised GitHub-hosted Ubuntu amd64 path? Recommendation: ship
  the exercised Ubuntu path first and add platforms with conformance fixtures.
- Should structured changed-range inputs be included in the first release?
  Recommendation: defer until whole-repository validation and terminal
  categories are stable.

---
*This document follows the https://specscore.md/feature-specification*
