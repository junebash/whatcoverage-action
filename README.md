# WhatCoverage Action

A thin, versioned GitHub Action for [WhatCoverage](https://github.com/junebash/WhatCoverage) PR diff coverage. It installs a pinned upstream release binary, verifies the archive against a checksum committed to this action, forwards inputs to the Swift CLI, and optionally upserts the Swift-rendered Markdown as a PR comment.

The action deliberately does **not** calculate coverage, interpret path policy, compare percentages, or render coverage Markdown. Those responsibilities remain in WhatCoverage. The only JSON field the wrapper reads is the tool's versioned `policy.status`, to expose an action output.

## Non-blocking mode

WhatCoverage consumes coverage that your test job has already produced. Fetch full history and check out the exact PR head so the requested revisions and covered sources agree.

```yaml
name: PR coverage

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write # omit this and set comment: false if comments are not wanted

jobs:
  whatcoverage:
    name: WhatCoverage (observing)
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - name: Test with coverage
        run: xcodebuild test -scheme MyApp -resultBundlePath TestResults.xcresult -enableCodeCoverage YES
      - name: Analyze changed lines
        id: coverage
        uses: junebash/whatcoverage-action@v1
        with:
          coverage-input: TestResults.xcresult
          base: ${{ github.event.pull_request.base.sha }}
          head: ${{ github.event.pull_request.head.sha }}
          blocking: false
      - run: echo "WhatCoverage policy was ${{ steps.coverage.outputs.policy-status }}"
```

`blocking: false` is the default. Installation, analysis, policy, and comment errors produce annotations and `outcome: error` or `failed`, but the step succeeds. Reports are also linked in the job summary. To make coverage mandatory:

1. Change `blocking` to `true` (or remove an explicit `false` after adopting a future blocking default).
2. In **Settings → Branches → Branch protection**, require the `WhatCoverage` job/check by its stable job name.

Do not rely only on `continue-on-error`: that makes branch-protection behavior harder to reason about and obscures whether the action itself was configured as a gate.

## Running beside other checks

[`examples/pr-coverage.yml`](examples/pr-coverage.yml) runs WhatCoverage and an unrelated quality check as independent jobs. The jobs do not depend on one another, so either result remains separately visible.

## Inputs

| Input                  | Default                     | Notes                                                                     |
| ---------------------- | --------------------------- | ------------------------------------------------------------------------- |
| `coverage-input`       | required                    | LLVM `llvm.coverage.json.export` JSON or Xcode `.xcresult`                |
| `base`                 | required                    | Prefer `github.event.pull_request.base.sha`                               |
| `head`                 | `HEAD`                      | Prefer the exact PR head SHA                                              |
| `format`               | inferred                    | `llvm` or `xcode`                                                         |
| `comparison`           | `merge-base`                | `merge-base` (PR semantics) or `direct`                                   |
| `captured-source-root` | unset                       | Absolute path used when coverage was captured elsewhere                   |
| `minimum`              | config                      | Number from 0 through 100; overrides config                               |
| `config`               | discovered                  | Explicit repo-relative strict TOML config                                 |
| `no-config`            | `false`                     | Disables `.whatcoverage.toml` discovery; mutually exclusive with `config` |
| `markdown-output`      | `what-coverage-report.md`   | Swift-rendered report                                                     |
| `json-output`          | `what-coverage-report.json` | WhatCoverage report schema v1                                             |
| `whatcoverage-version` | `0.6.0`                     | Must be present in this action release's `checksums.txt`                  |
| `executable`           | unset                       | Trusted local tool path; skips release download and checksum verification |
| `comment`              | `true`                      | Upsert one marked bot comment; requires `pull-requests: write`            |
| `pr-number`            | event PR                    | Required outside a `pull_request` event when commenting                   |
| `github-token`         | `github.token`              | Used only by the comment request                                          |
| `comment-author`       | `github-actions[bot]`       | Change when `github-token` belongs to another bot                         |
| `blocking`             | `false`                     | Return a failing action result for any action/policy failure              |

Outputs are `outcome` (`passed`, `failed`, `notApplicable`, or `error`), `policy-status`, `exit-code`, `markdown-report`, and `json-report`.

WhatCoverage exit code 2 means it wrote reports but failed the threshold. The action comments first, then fails when `blocking: true`. Other documented upstream failures (64/65/66/74) are surfaced without trying to recreate their meaning.

### Testing a locally built WhatCoverage

The upstream WhatCoverage repository (and tool contributors) must test the executable built from the PR rather than this action's released default. Pass the explicit `executable` input:

```yaml
- name: Build the PR's WhatCoverage
  run: swift build -c release --product what-coverage
- uses: junebash/whatcoverage-action@v1
  with:
    executable: .build/release/what-coverage
    coverage-input: .build/debug/codecov/WhatCoverage.json
    base: ${{ github.event.pull_request.base.sha }}
    head: ${{ github.event.pull_request.head.sha }}
    comment: false
    blocking: true
```

Relative executable paths are resolved from the repository root and must name an executable regular file. This is an explicit trust boundary: the action neither downloads nor verifies a supplied executable. Use it only for a tool intentionally built by the current job. Normal consumers should omit it and retain the checksum-verified installation path. `comment: false` is appropriate when upstream's separate trusted `workflow_run` renderer owns rich PR comments.

## Configuration

WhatCoverage discovers `.whatcoverage.toml` at the Git root. For example:

```toml
schema_version = 1
minimum = 60

[[paths]]
pattern = "**/Generated/**"
action = "exclude"
```

Path matching, last-match-wins behavior, threshold validation, changed executable-line calculation, and both report formats are owned by the Swift CLI. See the [upstream README](https://github.com/junebash/WhatCoverage) for the complete schema and coverage semantics.

## Permissions and private repositories

Use `contents: read` and add only `pull-requests: write` for comments. `actions/checkout` should use `persist-credentials: false`; the action does not need repository write access. The default `GITHUB_TOKEN` is sufficient in a private repository when Actions is allowed to create PR comments.

Pull requests from forks normally receive a read-only token, so comments may fail while analysis still works in non-blocking mode. Do **not** switch this workflow to `pull_request_target` and then execute or test untrusted PR code. For fork-heavy repositories, set `comment: false` in the unprivileged analysis job and use a separately reviewed `workflow_run` comment workflow. Upstream's richer source-excerpt comment flow demonstrates that trust boundary; v0.6.0 release archives currently contain only `what-coverage`, not `what-coverage-pr-comment`, so this action posts only the standard Markdown rendered by the released Swift binary.

The upsert escapes the whole report through `jq`, selects only comments whose author matches `comment-author` and which carry this action's versioned marker, follows issue-comment pagination, and never interprets Markdown content. When supplying a GitHub App or bot token, set `comment-author` to that account's login. Private repositories still send the report to GitHub as a PR comment; disable comments if coverage paths or counts are sensitive.

## Supported runners and caching

The upstream v0.6.0 release provides macOS arm64, macOS x86_64, and Linux x86_64 archives. Linux requires glibc 2.35 or newer (Ubuntu 22.04+/Debian 12+); Xcode input requires macOS with Xcode 16+. Git and `jq` are required.

The action caches the version/platform archive with `actions/cache`, re-verifies its pinned SHA-256 on every use, and extracts a fresh executable. The checksum is not downloaded from the same mutable release at runtime. Add a new version only after reviewing its release and copying all published platform checksums into `checksums.txt`.

## Releases and versioning

Action releases follow SemVer:

1. Update the pinned upstream version/checksums and run `tests/smoke.sh` on Linux and macOS.
2. Create a signed, immutable action tag such as `v1.0.0` from the reviewed commit and publish release notes naming the upstream version.
3. Move the convenience major tag (`v1`) to that exact commit. Consumers wanting immutability should pin the full commit SHA; consumers accepting reviewed compatible updates can use `@v1`.
4. Never move or recreate a full SemVer tag. Use a new patch/minor/major tag for every change.

No generated JavaScript bundle or dependency update is required: this is a small composite action whose checked-in Bash only installs, invokes, and transports the Swift tool's output.

## Development

```bash
tests/smoke.sh
tests/comment.sh
```

The smoke test downloads and verifies the real v0.6.0 Linux/macOS archive, rejects a corrupted cached archive, checks `--help`, creates a two-commit Git fixture plus LLVM export, verifies Swift's threshold-failure reports, and exercises both non-blocking and blocking wrapper behavior. The comment test uses a fake API transport to verify safe JSON payload creation and both create/update paths. CI runs both on Ubuntu 22.04 and macOS 14.
