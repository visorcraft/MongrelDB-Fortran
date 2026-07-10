# Security

This document describes the security properties of the MongrelDB Fortran client
and how to report vulnerabilities.

## Overview

The MongrelDB Fortran client is a Modern Fortran 2018 library that talks to
`mongreldb-server` over HTTP. The transport shells out to the system `curl`
binary, and JSON is handled by a bundled parser (`mongreldb_json`) - no
external Fortran libraries are required. The client itself holds no encryption
keys and stores no data at rest; it is a thin request/response layer over the
daemon.

## Client security properties

- The client communicates with `mongreldb-server` over plain HTTP. The
  daemon binds to `127.0.0.1` by default - traffic stays on the loopback
  interface. For remote or multi-tenant deployments, terminate TLS in a
  reverse proxy (nginx, Caddy) in front of the daemon.
- The client supports Bearer token and HTTP Basic auth, matching the
  daemon's `--auth-token` and `--auth-users` modes. Credentials are sent
  only in the `Authorization` header and are never logged by the client.
- The native condition API and query builder accept typed parameters
  (column IDs, typed values) - no string interpolation, no SQL injection
  surface. User-supplied values are serialized as typed JSON, not
  concatenated into queries.
- **WARNING - raw SQL:** The `sql` method sends a raw SQL string to the
  server. It does NOT parameterize or sanitize input, and the client never
  interprets SQL locally. Never interpolate untrusted user input into SQL
  statements - validate/escape input yourself. (The native condition API and
  query builder remain type-safe and are not affected.)
- Idempotency keys are caller-supplied opaque strings; the client does not
  derive or store them.
- The bundled JSON parser is strict about structure and rejects malformed
  input with `MDB_ERR_JSON` rather than reading out of bounds.
- The client caps response bodies at 256 MiB (`MDB_MAX_RESPONSE_BYTES`)
  so a runaway query or a misbehaving daemon cannot exhaust memory.
- Table names are URL-percent-encoded into path segments, so a name
  containing `/`, `?`, `#`, or spaces cannot inject extra segments or break
  routing.
- The `curl` transport never follows HTTP redirects (`--max-redirs 0`). An
  `Authorization` header that followed a redirect to an attacker-controlled
  host would leak credentials, so redirects are rejected.
- The `curl` transport is invoked with `--noproxy '*'` so proxy environment
  variables are never honored. This prevents DB auth/data leaking to a proxy.

## CR/LF validation

Token, username, and password values are placed verbatim into the
`Authorization` header. The connect methods reject any credential that
contains a carriage return (`char(13)`) or newline (`char(10)`) before the
first request is sent. This prevents HTTP request splitting via header
injection:

```fortran
! Sets stat = MDB_ERR_AUTH - never sends the request.
call db%connect_with_token(url, 'evil' // char(13) // char(10), stat, errmsg)
```

## Daemon security (mongreldb-server)

The client is a consumer of `mongreldb-server`. The daemon's security
posture:

- Binds to `127.0.0.1` only - not accessible from other machines.
- **No authentication by default** - any local process can query, write, or
  delete data. Enable `--auth-token` or `--auth-users` for any shared host.
- No TLS - traffic is plaintext on the loopback interface.
- No rate limiting or request size caps.

For remote access or multi-tenant environments, place a reverse proxy
(nginx, Caddy) in front with TLS termination and authentication. Do not
expose the daemon directly to a network.

## Input validation

- The query builder produces typed JSON requests. Invalid column IDs, value
  encodings, and numeric ranges are rejected before any request is sent.
- Server and network errors are mapped to the typed code hierarchy
  (`MDB_ERR_AUTH`, `MDB_ERR_NOT_FOUND`, `MDB_ERR_CONFLICT`, `MDB_ERR_QUERY`,
  `MDB_ERR_NETWORK`, `MDB_ERR_JSON`, `MDB_ERR_INVALID_ARG`), not leaked as
  generic failures.

## Dependency security

The MongrelDB Fortran client depends on:

- **gfortran** (or another Fortran compiler) - keep it patched via your
  system package manager.
- **The system `curl` binary** - keep it patched via your system package
  manager. Report curl vulnerabilities through your distribution's security
  channel or GitHub's private vulnerability reporting flow below.

No Fortran-specific third-party libraries are required.

## Reporting a vulnerability

**Do not file a public GitHub issue, discussion, or pull request for
security problems.** Report privately through **GitHub's private
vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with the details below.

This keeps the report confidential between you and the maintainers
until a fix is ready. Please include as much as you can:

- a description of the issue and its impact,
- step-by-step reproduction steps,
- the MongrelDB Fortran client version, compiler version, and OS,
- the `mongreldb-server` version if relevant,
- the relevant configuration, error output, or a proof-of-concept,
- a suggested fix or mitigation, if you have one.

### What to expect

- **Acknowledgement** of your report within a few days.
- An initial assessment and, where confirmed, a remediation plan.
- Progress updates through the private advisory thread until the
  issue is resolved.
- Credit for your responsible disclosure in the advisory, unless you
  prefer to remain anonymous.

We ask that you give us a reasonable opportunity to ship a fix before
any public disclosure.
