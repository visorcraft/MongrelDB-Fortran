!> MongrelDB Fortran client.
!>
!> Pure Modern Fortran 2018 HTTP client for `mongreldb-server`. Talks JSON
!> over the Kit transaction, query, and SQL endpoints, with a typed error
!> category and a native query builder.
!>
!> The HTTP transport shells out to the system `curl` binary (see
!> `mongreldb_http`), and JSON is handled by the bundled `mongreldb_json`
!> module - no external Fortran libraries are required.
!>
!> Usage:
!>   use mongreldb
!>   type(mongreldb_client) :: db
!>   integer :: stat
!>   call db%connect('http://127.0.0.1:8453', stat)
!>   call db%create_table('orders', columns, stat)
module mongreldb
  use iso_fortran_env, only: int64, real64
  use mongreldb_json
  use mongreldb_http
  implicit none
  private

  public :: mongreldb_client
  public :: MDB_OK, MDB_ERR_AUTH, MDB_ERR_NOT_FOUND, MDB_ERR_CONFLICT, &
            MDB_ERR_QUERY, MDB_ERR_NETWORK, MDB_ERR_JSON, MDB_ERR_INVALID_ARG
  public :: MDB_DEFAULT_URL, MDB_MAX_RESPONSE_BYTES

  !> Default daemon URL.
  character(*), parameter :: MDB_DEFAULT_URL = 'http://127.0.0.1:8453'
  !> Response body size cap: 256 MiB.
  integer(int64), parameter :: MDB_MAX_RESPONSE_BYTES = &
    256_int64 * 1024_int64 * 1024_int64

  !> Error code constants. Non-positive on error, zero on success.
  integer, parameter :: MDB_OK            = 0
  integer, parameter :: MDB_ERR_AUTH      = -1
  integer, parameter :: MDB_ERR_NOT_FOUND = -2
  integer, parameter :: MDB_ERR_CONFLICT  = -3
  integer, parameter :: MDB_ERR_QUERY     = -4
  integer, parameter :: MDB_ERR_NETWORK   = -5
  integer, parameter :: MDB_ERR_JSON      = -6
  integer, parameter :: MDB_ERR_INVALID_ARG = -8

  !> The client handle. Holds the base URL and an optional Authorization
  !> header value. A client is not thread-safe (Fortran has no user threads
  !> in scope here) but is safe to pass around and reuse.
  type :: mongreldb_client
    character(:), allocatable :: url
    character(:), allocatable :: auth_header
    integer(int64) :: max_bytes = MDB_MAX_RESPONSE_BYTES
  contains
    procedure :: connect => client_connect
    procedure :: connect_with_token => client_connect_token
    procedure :: connect_with_basic_auth => client_connect_basic
    procedure :: health => client_health
    procedure :: tables => client_tables
    procedure :: create_table => client_create_table
    procedure :: drop_table => client_drop_table
    procedure :: count => client_count
    procedure :: put => client_put
    procedure :: upsert => client_upsert
    procedure :: delete => client_delete
    procedure :: delete_by_pk => client_delete_by_pk
    procedure :: transaction => client_transaction
    procedure :: query => client_query
    procedure :: sql => client_sql
    procedure :: schema => client_schema
    procedure :: schema_for => client_schema_for
    procedure, private :: do_request => client_do_request
    procedure, private :: set_err => client_set_err
  end type mongreldb_client

contains

  ! ---- Connection ---------------------------------------------------------

  subroutine client_connect(this, url, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: url
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    this%url = url
    if (allocated(this%auth_header)) deallocate(this%auth_header)
    this%max_bytes = MDB_MAX_RESPONSE_BYTES
    stat = MDB_OK
    if (present(errmsg)) errmsg = ''
  end subroutine

  subroutine client_connect_token(this, url, token, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: url
    character(*), intent(in) :: token
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    call validate_no_crlf('token', token, stat, errmsg)
    if (stat /= MDB_OK) return
    this%url = url
    this%auth_header = 'Bearer ' // token
    this%max_bytes = MDB_MAX_RESPONSE_BYTES
  end subroutine

  subroutine client_connect_basic(this, url, username, password, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: url
    character(*), intent(in) :: username
    character(*), intent(in) :: password
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    call validate_no_crlf('username', username, stat, errmsg)
    if (stat /= MDB_OK) return
    call validate_no_crlf('password', password, stat, errmsg)
    if (stat /= MDB_OK) return
    this%url = url
    ! Basic auth: base64(username:password). We do a minimal base64 encode.
    this%auth_header = 'Basic ' // base64_encode(username // ':' // password)
    this%max_bytes = MDB_MAX_RESPONSE_BYTES
  end subroutine

  ! ---- Health -------------------------------------------------------------

  !> GET /health. Returns .true. if the daemon answered; never sets stat to an
  !> error (so it is safe for startup checks).
  function client_health(this) result(ok)
    class(mongreldb_client), intent(inout) :: this
    logical :: ok
    type(http_response) :: resp
    character(:), allocatable :: payload
    integer :: stat
    character(256) :: msg
    ok = .false.
    resp = this%do_request('GET', 'health', payload, stat, msg)
    ok = (stat == MDB_OK)
  end function

  ! ---- Tables -------------------------------------------------------------

  !> GET /tables. Returns the list of table names.
  function client_tables(this, stat, errmsg) result(names)
    class(mongreldb_client), intent(inout) :: this
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: names(:)
    type(http_response) :: resp
    type(json_value) :: doc
    character(:), allocatable :: payload
    integer :: i, n
    character(256) :: msg
    stat = MDB_OK
    resp = this%do_request('GET', 'tables', payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      allocate(character(0) :: names(0))
      return
    end if
    call json_parse(resp%body, doc, stat, msg)
    if (stat /= 0) then
      call this%set_err(MDB_ERR_JSON, 'failed to parse tables response', errmsg)
      allocate(character(0) :: names(0))
      return
    end if
    if (doc%kind /= JSON_ARRAY) then
      allocate(character(0) :: names(0))
      return
    end if
    n = size(doc%children)
    allocate(character(256) :: names(n))
    do i = 1, n
      if (doc%children(i)%kind == JSON_STRING) then
        names(i) = doc%children(i)%str_val
      else
        names(i) = ''
      end if
    end do
  end function

  ! ---- create_table -------------------------------------------------------

  !> POST /kit/create_table. `columns_json` is the serialized columns array.
  !> Sets `table_id` to the new table id, or 0 if none was reported.
  subroutine client_create_table(this, name, columns_json, stat, errmsg, table_id)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: name
    character(*), intent(in) :: columns_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    integer(int64), intent(out), optional :: table_id
    type(http_response) :: resp
    type(json_value) :: body, cols, doc
    character(:), allocatable :: payload
    integer :: jstat
    integer(int64) :: tid
    character(256) :: msg

    tid = 0
    ! Re-parse the caller's column JSON so we can embed it as a structured
    ! value (rather than concatenating raw text, which risks malformed JSON).
    call json_parse(columns_json, cols, jstat, msg)
    if (jstat /= 0) then
      call this%set_err(MDB_ERR_INVALID_ARG, 'invalid columns JSON: ' // msg, errmsg)
      if (present(table_id)) table_id = 0
      return
    end if
    body = json_make_object()
    call json_object_set_str(body, 'name', name)
    call json_object_set(body, 'columns', cols)
    payload = json_serialize(body)

    resp = this%do_request('POST', 'kit/create_table', payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      if (present(table_id)) table_id = 0
      return
    end if
    call json_parse(resp%body, doc, jstat, msg)
    if (jstat == 0) then
      if (json_object_has(doc, 'table_id')) then
        block
          type(json_value) :: tid_val
          tid_val = json_object_get(doc, 'table_id')
          if (tid_val%kind == JSON_INT) tid = tid_val%int_val
        end block
      end if
    end if
    if (present(table_id)) table_id = tid
  end subroutine

  subroutine client_drop_table(this, name, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: name
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    type(http_response) :: resp
    character(:), allocatable :: payload
    character(256) :: msg
    resp = this%do_request('DELETE', 'tables/' // encode_segment(name), &
                           payload, stat, msg)
    if (stat /= MDB_OK) call this%set_err(stat, msg, errmsg)
  end subroutine

  function client_count(this, table, stat, errmsg) result(n)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: table
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    integer(int64) :: n
    type(http_response) :: resp
    type(json_value) :: doc
    character(:), allocatable :: payload
    integer :: jstat
    character(256) :: msg
    n = 0
    resp = this%do_request('GET', 'tables/' // encode_segment(table) // '/count', &
                           payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      return
    end if
    call json_parse(resp%body, doc, jstat, msg)
    if (jstat /= 0 .or. .not. json_object_has(doc, 'count')) then
      call this%set_err(MDB_ERR_JSON, 'malformed count response', errmsg)
      return
    end if
    block
      type(json_value) :: cnt_val
      cnt_val = json_object_get(doc, 'count')
      if (cnt_val%kind == JSON_INT) n = cnt_val%int_val
    end block
  end function

  ! ---- Write helpers ------------------------------------------------------

  !> Single-op put. `cells` is the flat {colId value colId value ...} list.
  subroutine client_put(this, table, cells_json, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: table
    character(*), intent(in) :: cells_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: ops_json
    ops_json = '[{"put":{"table":"' // escape_for_json(table) // &
               '","cells":' // cells_json // '}}]'
    call run_txn(this, ops_json, stat, errmsg)
  end subroutine

  !> Single-op upsert.
  subroutine client_upsert(this, table, cells_json, update_json, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: table
    character(*), intent(in) :: cells_json
    character(*), intent(in), optional :: update_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: ops_json
    ops_json = '[{"upsert":{"table":"' // escape_for_json(table) // &
               '","cells":' // cells_json
    if (present(update_json)) then
      if (len_trim(update_json) > 0) then
        ops_json = ops_json // ',"update_cells":' // update_json
      end if
    end if
    ops_json = ops_json // '}}]'
    call run_txn(this, ops_json, stat, errmsg)
  end subroutine

  subroutine client_delete(this, table, row_id, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: table
    integer(int64), intent(in) :: row_id
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: ops_json
    character(32) :: rid
    write(rid, '(I0)') row_id
    ops_json = '[{"delete":{"table":"' // escape_for_json(table) // &
               '","row_id":' // trim(rid) // '}}]'
    call run_txn(this, ops_json, stat, errmsg)
  end subroutine

  subroutine client_delete_by_pk(this, table, pk_json, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: table
    character(*), intent(in) :: pk_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: ops_json
    ops_json = '[{"delete_by_pk":{"table":"' // escape_for_json(table) // &
               '","pk":' // pk_json // '}}]'
    call run_txn(this, ops_json, stat, errmsg)
  end subroutine

  !> Multi-op transaction. `ops_json` is the full ops array; `idem_key` is
  !> optional. Returns the response body via `results_json` for the caller
  !> to parse.
  subroutine client_transaction(this, ops_json, results_json, stat, errmsg, idem_key)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: ops_json
    character(:), allocatable, intent(out) :: results_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(*), intent(in), optional :: idem_key
    type(http_response) :: resp
    type(json_value) :: body
    character(:), allocatable :: payload
    integer :: jstat
    character(256) :: msg

    body = json_make_object()
    call parse_and_set(body, 'ops', ops_json, jstat, msg)
    if (jstat /= 0) then
      call this%set_err(MDB_ERR_INVALID_ARG, 'invalid ops JSON: ' // msg, errmsg)
      results_json = '[]'
      return
    end if
    if (present(idem_key)) then
      if (len_trim(idem_key) > 0) then
        call json_object_set_str(body, 'idempotency_key', idem_key)
      end if
    end if
    payload = json_serialize(body)

    resp = this%do_request('POST', 'kit/txn', payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      results_json = '[]'
      return
    end if
    results_json = resp%body
    if (.not. allocated(results_json)) results_json = '{}'
  end subroutine

  ! ---- Query --------------------------------------------------------------

  !> POST /kit/query. `query_json` is the serialized query body.
  subroutine client_query(this, query_json, result_json, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: query_json
    character(:), allocatable, intent(out) :: result_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    type(http_response) :: resp
    character(:), allocatable :: payload
    character(256) :: msg
    integer :: jstat
    type(json_value) :: body
    ! Validate the query body parses as JSON before sending.
    call json_parse(query_json, body, jstat, msg)
    if (jstat /= 0) then
      call this%set_err(MDB_ERR_INVALID_ARG, 'invalid query JSON: ' // msg, errmsg)
      result_json = '{}'
      return
    end if
    payload = query_json
    resp = this%do_request('POST', 'kit/query', payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      result_json = '{}'
      return
    end if
    result_json = resp%body
    if (.not. allocated(result_json)) result_json = '{}'
  end subroutine

  ! ---- SQL ----------------------------------------------------------------

  subroutine client_sql(this, statement, result_json, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: statement
    character(:), allocatable, intent(out) :: result_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    type(http_response) :: resp
    type(json_value) :: body
    character(:), allocatable :: payload
    character(256) :: msg
    body = json_make_object()
    call json_object_set_str(body, 'sql', statement)
    call json_object_set_str(body, 'format', 'json')
    payload = json_serialize(body)
    resp = this%do_request('POST', 'sql', payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      result_json = '{}'
      return
    end if
    result_json = resp%body
    if (.not. allocated(result_json)) result_json = '{}'
  end subroutine

  ! ---- Schema -------------------------------------------------------------

  function client_schema(this, stat, errmsg) result(tables_json)
    class(mongreldb_client), intent(inout) :: this
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: tables_json
    type(http_response) :: resp
    character(:), allocatable :: payload
    character(256) :: msg
    resp = this%do_request('GET', 'kit/schema', payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      tables_json = '{}'
      return
    end if
    tables_json = resp%body
    if (.not. allocated(tables_json)) tables_json = '{}'
  end function

  function client_schema_for(this, table, stat, errmsg) result(desc_json)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: table
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: desc_json
    type(http_response) :: resp
    character(:), allocatable :: payload
    character(256) :: msg
    resp = this%do_request('GET', 'kit/schema/' // encode_segment(table), &
                           payload, stat, msg)
    if (stat /= MDB_OK) then
      call this%set_err(stat, msg, errmsg)
      desc_json = '{}'
      return
    end if
    desc_json = resp%body
    if (.not. allocated(desc_json)) desc_json = '{}'
  end function

  ! ---- Core request dispatch ----------------------------------------------

  !> Central request helper shared by every public method. Sends the request,
  !> maps HTTP/transport errors to error codes, and returns the raw response.
  function client_do_request(this, method, path, payload, stat, errmsg) result(resp)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: method
    character(*), intent(in) :: path
    character(:), allocatable, intent(in) :: payload
    integer, intent(out) :: stat
    character(*), intent(out) :: errmsg
    type(http_response) :: resp
    character(:), allocatable :: url, body_msg, code_msg
    integer :: jstat
    type(json_value) :: errdoc

    stat = MDB_OK
    errmsg = ''
    code_msg = ''
    url = this%url // '/' // path

    resp = http_request(url, method, payload, this%auth_header, this%max_bytes)

    ! Transport failure: curl exited with no HTTP status.
    if (resp%status == 0) then
      stat = MDB_ERR_NETWORK
      if (allocated(resp%err)) then
        errmsg = resp%err
      else
        errmsg = 'network error'
      end if
      return
    end if

    ! Non-2xx: map to an error category and extract the server's message.
    if (resp%status >= 400) then
      body_msg = ''
      if (allocated(resp%body)) then
        call json_parse(resp%body, errdoc, jstat, code_msg)
        if (jstat == 0) then
          if (json_object_has(errdoc, 'error')) then
            block
              type(json_value) :: err_field, inner
              err_field = json_object_get(errdoc, 'error')
              if (err_field%kind == JSON_OBJECT) then
                if (json_object_has(err_field, 'message')) then
                  inner = json_object_get(err_field, 'message')
                  if (inner%kind == JSON_STRING) body_msg = inner%str_val
                end if
              else if (err_field%kind == JSON_STRING) then
                body_msg = err_field%str_val
              end if
            end block
          end if
        end if
      end if
      if (len_trim(body_msg) == 0) then
        write(errmsg, '(A,I0,A)') 'Server error (', resp%status, ')'
      else
        errmsg = trim(body_msg)
      end if
      stat = status_to_code(resp%status)
    end if
  end function

  ! ---- Internal helpers ---------------------------------------------------

  !> Run a single-op txn given a pre-built ops array string.
  subroutine run_txn(this, ops_json, stat, errmsg)
    class(mongreldb_client), intent(inout) :: this
    character(*), intent(in) :: ops_json
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    character(:), allocatable :: payload
    type(json_value) :: body
    integer :: jstat
    character(256) :: msg
    body = json_make_object()
    call parse_and_set(body, 'ops', ops_json, jstat, msg)
    if (jstat /= 0) then
      call this%set_err(MDB_ERR_INVALID_ARG, 'invalid ops JSON: ' // msg, errmsg)
      return
    end if
    payload = json_serialize(body)
    block
      type(http_response) :: resp
      resp = this%do_request('POST', 'kit/txn', payload, stat, msg)
      if (stat /= MDB_OK) call this%set_err(stat, msg, errmsg)
    end block
  end subroutine

  !> Parse a JSON fragment string and attach it to an object under `key`.
  subroutine parse_and_set(obj, key, fragment, stat, errmsg)
    type(json_value), intent(inout) :: obj
    character(*), intent(in) :: key
    character(*), intent(in) :: fragment
    integer, intent(out) :: stat
    character(*), intent(out) :: errmsg
    type(json_value) :: v
    call json_parse(fragment, v, stat, errmsg)
    if (stat /= 0) return
    call json_object_set(obj, key, v)
    stat = 0
  end subroutine

  subroutine client_set_err(this, stat, msg, errmsg)
    class(mongreldb_client), intent(inout) :: this
    integer, intent(in) :: stat
    character(*), intent(in) :: msg
    character(*), intent(out), optional :: errmsg
    ! Associate the passed-object and status arguments so the compiler does
    ! not flag them unused; the error code is already in `stat` on the caller
    ! side and this routine exists only to surface the message.
    if (.false.) then
      if (len(this%url) >= 0 .and. stat == stat) return
    end if
    if (present(errmsg)) errmsg = msg
  end subroutine

  ! ---- Module-level helpers ----------------------------------------------

  !> Map an HTTP status to a client error code.
  function status_to_code(status) result(code)
    integer, intent(in) :: status
    integer :: code
    select case (status)
    case (401, 403)
      code = MDB_ERR_AUTH
    case (404)
      code = MDB_ERR_NOT_FOUND
    case (409)
      code = MDB_ERR_CONFLICT
    case default
      ! 400 and all 5xx land in the generic query bucket.
      code = MDB_ERR_QUERY
    end select
  end function

  !> Reject CR/LF in a credential value. Header injection guard.
  subroutine validate_no_crlf(field, value, stat, errmsg)
    character(*), intent(in) :: field
    character(*), intent(in) :: value
    integer, intent(out) :: stat
    character(*), intent(out), optional :: errmsg
    integer :: i
    stat = MDB_OK
    do i = 1, len(value)
      if (value(i:i) == char(10) .or. value(i:i) == char(13)) then
        stat = MDB_ERR_AUTH
        if (present(errmsg)) errmsg = 'auth ' // field // ' must not contain CR or LF'
        return
      end if
    end do
  end subroutine

  !> Percent-encode a single URL path segment so a table name containing '/',
  !> '?', '#', or spaces cannot inject extra segments or break routing.
  function encode_segment(seg) result(enc)
    character(*), intent(in) :: seg
    character(:), allocatable :: enc
    integer :: i
    character :: c
    enc = ''
    do i = 1, len(seg)
      c = seg(i:i)
      if ((c >= 'A' .and. c <= 'Z') .or. (c >= 'a' .and. c <= 'z') .or. &
          (c >= '0' .and. c <= '9') .or. c == '-' .or. c == '_' .or. &
          c == '.' .or. c == '~') then
        enc = enc // c
      else
        enc = enc // '%' // hex2(ichar(c))
      end if
    end do
  end function

  function hex2(n) result(s)
    integer, intent(in) :: n
    character(2) :: s
    character(*), parameter :: hex = '0123456789ABCDEF'
    s(1:1) = hex(iand(ishft(n,-4),15)+1:iand(ishft(n,-4),15)+1)
    s(2:2) = hex(iand(n,15)+1:iand(n,15)+1)
  end function

  !> Escape a string for embedding inside a JSON string literal.
  function escape_for_json(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: i
    character :: c
    out = ''
    do i = 1, len(s)
      c = s(i:i)
      select case (c)
      case ('"');  out = out // '\"'
      case ('\');  out = out // '\\'
      case (char(10)); out = out // '\n'
      case (char(13)); out = out // '\r'
      case (char(9));  out = out // '\t'
      case default; out = out // c
      end select
    end do
  end function

  !> Minimal Base64 encoding for HTTP Basic auth.
  function base64_encode(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    character(*), parameter :: alphabet = &
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    integer :: i, n, b, j, outlen
    character, allocatable :: bytes(:)
    n = len(s)
    allocate(bytes(n))
    do i = 1, n
      bytes(i) = s(i:i)
    end do
    outlen = ((n + 2) / 3) * 4
    allocate(character(outlen) :: out)
    j = 0
    i = 1
    do while (i + 2 <= n)
      b = ior(ishft(iachar(bytes(i)),16), &
              ior(ishft(iachar(bytes(i+1)),8), iachar(bytes(i+2))))
      j = j + 1
      out(j:j) = alphabet(iand(ishft(b,-18),63)+1:iand(ishft(b,-18),63)+1)
      j = j + 1
      out(j:j) = alphabet(iand(ishft(b,-12),63)+1:iand(ishft(b,-12),63)+1)
      j = j + 1
      out(j:j) = alphabet(iand(ishft(b,-6),63)+1:iand(ishft(b,-6),63)+1)
      j = j + 1
      out(j:j) = alphabet(iand(b,63)+1:iand(b,63)+1)
      i = i + 3
    end do
    ! Handle remainder.
    if (i <= n) then
      b = ishft(iachar(bytes(i)),16)
      if (i + 1 <= n) b = ior(b, ishft(iachar(bytes(i+1)),8))
      j = j + 1
      out(j:j) = alphabet(iand(ishft(b,-18),63)+1:iand(ishft(b,-18),63)+1)
      j = j + 1
      out(j:j) = alphabet(iand(ishft(b,-12),63)+1:iand(ishft(b,-12),63)+1)
      if (i + 1 <= n) then
        j = j + 1
        out(j:j) = alphabet(iand(ishft(b,-6),63)+1:iand(ishft(b,-6),63)+1)
        j = j + 1
        out(j:j) = '='
      else
        j = j + 1
        out(j:j) = '='
        j = j + 1
        out(j:j) = '='
      end if
    end if
  end function

end module
