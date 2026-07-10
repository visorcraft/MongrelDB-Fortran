# Authentication

`mongreldb-server` accepts an optional `--auth-token` (bearer) or
`--auth-users` (basic auth) flag at startup. When the daemon is started with
either, every request must carry a matching `Authorization` header or the
server returns 401/403.

This document covers how the Fortran client attaches credentials.

---

## Three connect methods

| Method | Auth scheme | When to use |
|---------|-------------|-------------|
| `connect(url, ...)` | none | Daemon started without `--auth-*`. |
| `connect_with_token(url, token, ...)` | Bearer | Daemon started with `--auth-token <T>`. |
| `connect_with_basic_auth(url, user, pass, ...)` | Basic | Daemon started with `--auth-users`. |

```fortran
! No auth
call db%connect('http://127.0.0.1:8453', stat, errmsg)

! Bearer token
call get_environment_variable('MDB_TOKEN', token)
call db%connect_with_token('http://127.0.0.1:8453', trim(token), stat, errmsg)

! HTTP Basic
call db%connect_with_basic_auth('http://127.0.0.1:8453', 'alice', secret, &
                                stat, errmsg)
```

The header is set once at connect time and attached to every subsequent
request on that client. There is no per-call auth override.

## Where credentials live

The client stores the formatted `Authorization` header value in the client
derived type. It never logs credentials and never writes them to disk. The
header is discarded when the client goes out of scope.

## CR/LF rejection

The connect methods reject any token, username, or password that contains a
carriage return or newline. These characters are placed verbatim into the
`Authorization` header, so an embedded CR/LF would allow header injection
(HTTP request splitting). The guard runs before the first request is sent:

```fortran
! Sets stat = MDB_ERR_AUTH before any request is sent.
call db%connect_with_token(url, 'evil' // char(13) // char(10) // &
                                  'X-Injected: yes', stat, errmsg)
```

This is a defense-in-depth measure; well-behaved callers will never trip it,
but it prevents a malformed credential from smuggling a second header.

## Transport security

The client speaks plain HTTP via the system `curl` binary. The daemon binds
to `127.0.0.1` by default, so traffic stays on the loopback interface and
never leaves the host.

For remote or multi-tenant deployments, do **not** expose the daemon
directly. Put a reverse proxy (nginx, Caddy) in front of it to terminate TLS
and enforce authentication. Point the client at the proxy URL:

```fortran
call db%connect_with_token('https://mdb.internal.example.com', token, &
                           stat, errmsg)
```

The curl transport is invoked with `--noproxy '*'` so proxy environment
variables are never honored, and `--max-redirs 0` so an `Authorization`
header cannot follow a redirect to an attacker-controlled host.

## Token vs basic auth

- **Bearer token** is simpler: one shared secret, set via `--auth-token` on
  the daemon. Use it for single-user or service-to-service setups.
- **Basic auth** maps to a user list on the daemon (`--auth-users`). Use it
  when you need per-user identity for audit or role-based access. The client
  base64-encodes `username:password` internally.

Neither scheme has any client-side notion of users or roles. The client just
attaches the header; the daemon decides whether to accept it.

## When auth fails

A bad or missing credential surfaces as a `MDB_ERR_AUTH` code on the very
first request:

```fortran
n = db%count('orders', stat, errmsg)
if (stat == MDB_ERR_AUTH) then
  print *, 'credential rejected: ', trim(errmsg)
end if
```

The client does not retry on auth failures - the credential is wrong, and
re-sending it will not help. Fix the token or password and reconnect with a
fresh client.

## Daemon-side setup

This is a server concern, not a client one, but for completeness:

```sh
# Bearer token mode
mongreldb-server --auth-token "$MDB_TOKEN" /path/to/data

# Basic auth mode (user:pass hash file)
mongreldb-server --auth-users /path/to/users.htpasswd /path/to/data
```

Consult the `mongreldb-server` documentation for the exact flag format and
user-file layout.

## Next steps

- [quickstart.md](quickstart.md) - connect and run your first query
- [errors.md](errors.md) - the `MDB_ERR_AUTH` code and recovery
- [SECURITY.md](../SECURITY.md) - the full client security model
