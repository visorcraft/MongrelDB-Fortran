# Contributing to MongrelDB Fortran

Thanks for taking the time to help the MongrelDB Fortran client. This document
describes how to propose a change, what we expect from a pull request, and
the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical
details, not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB Fortran client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Fortran`](https://github.com/visorcraft/MongrelDB-Fortran)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-Fortran.git
   cd MongrelDB-Fortran
   git remote add upstream https://github.com/visorcraft/MongrelDB-Fortran.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-decode`, `feature/array-bind`, `docs/auth-guide`.

   ```sh
   git fetch upstream
   git switch -c my-change upstream/master
   ```

4. **Make focused commits.** One logical change per commit. Run the
   preflight (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-Fortran`.
   Fill in the PR template:
   - **What.** One paragraph summary of the change.
   - **Why.** Bug fix? New feature? Doc fix? Link the issue if one
     exists.
   - **How to test.** The exact commands a reviewer should run.
   - **Risk.** What might break? What did you not test?

## Before you push: preflight

The offline wire-shape test runs without a server and exercises JSON
encoding/parsing, URL encoding, error mapping, and CR/LF validation. Run it
on every change:

```sh
fpm test wire_shape --profile debug
```

To run the live integration suite (requires a running `mongreldb-server`):

```sh
# Either boot a local daemon:
./bin/mongreldb-server /tmp/mdb-data --port 8453 &
MONGRELDB_URL=http://127.0.0.1:8453 fpm test live_conformance --profile debug

# Or point at an already-running one:
MONGRELDB_URL=http://127.0.0.1:8453 fpm test live_conformance --profile debug
```

Live tests self-skip when no server is reachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test
  alongside the code. Wire-format changes: cover the exact outgoing JSON
  keys. Daemon-dependent coverage: a live test that skips cleanly when no
  server is available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Fortran

- **Version.** Fortran 2018 (free form). The build is tested with gfortran
  11+; do not use compiler-specific extensions that gfortran rejects.
- **Style.** 2-space indent, no tabs. `implicit none` in every scope
  (program, module, and every procedure with its own scope). `intent(in/out/
  inout)` on every dummy argument. Prefer `use, non_intrinsic` for this
  project's own modules.
- **Naming.** `snake_case` for procedures and variables. `mongreldb_*` for
  module names and public symbols. Derived types carry the `_t` suffix is
  not required; matching the surrounding style is what matters.
- **Memory.** Use allocatables (not raw pointers) wherever possible so the
  compiler manages lifetime. For `json_value` trees, the allocatable
  components auto-deallocate on scope exit. Document any manual deallocation.
- **Errors.** Return an `integer, intent(out) :: stat` from every public
  procedure. Use the `MDB_*` constants, never a raw integer literal at the
  call site. Set `errmsg` (when present) to a short, actionable message.
- **Dependencies.** Only the Fortran standard library (`iso_fortran_env`).
  The bundled `mongreldb_json` and `mongreldb_http` modules are the only
  internal dependencies. New third-party dependencies must be MIT or
  Apache-2.0 licensed and justified, and must not complicate the fpm build.
- **HTTP transport.** The `curl`-backed transport must always run with
  `--noproxy '*'`, `--max-redirs 0`, and `--max-filesize <cap>`. Do not add
  flags that weaken these guarantees.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
  Example: `Add FM-index full-text condition to query builder`.
- Body: wrap at 72 characters. Explain *why*, not *what* (the diff
  shows the what).
- Reference issues with `Fixes #123` / `Refs #123` on a final line
  when applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no
  `Generated with`, no tool names).

## Issue reports

A useful bug report includes:

- The MongrelDB Fortran client version (from git tag).
- Your compiler and version (`gfortran --version`) and OS.
- The `mongreldb-server` version if the issue involves live requests.
- The exact code or commands that reproduce the issue.
- The expected result and the actual result.
- Any error output or stack trace.

Feature requests are welcome. Please describe the problem you're trying
to solve before proposing the solution.

## Security

If you find a vulnerability, **do not** open a public GitHub issue.
Report it privately through GitHub's private vulnerability reporting -
the repository's **Security** tab -> **Report a vulnerability**. The full
policy is in [`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Fortran client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the
same license.

- Do **not** paste code from other database clients unless you have done
  a license review first.
- New third-party dependencies must be MIT or Apache-2.0 licensed.

Thanks again - looking forward to your PR.
