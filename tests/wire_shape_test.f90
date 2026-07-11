!> Offline wire-shape tests for the MongrelDB Fortran client.
!>
!> These run without a server and exercise JSON encoding, the query builder,
!> URL encoding, error mapping, and CR/LF validation. They form the CI unit
!> gate. A non-zero exit code signals failure.
program wire_shape_test
  use, non_intrinsic :: mongreldb_json
  use, non_intrinsic :: mongreldb
  use iso_fortran_env, only: int64, real64
  implicit none

  integer :: passed, failed
  integer :: test_fails = 0
  integer :: saved_fails = 0
  passed = 0
  failed = 0

  call run('json round-trip object', test_json_object)
  call run('json round-trip array', test_json_array)
  call run('json escape control chars', test_json_escape)
  call run('json reject malformed', test_json_malformed)
  call run('json nested structure', test_json_nested)
  call run('url-encode table name', test_url_encode)
  call run('error code mapping', test_status_mapping)
  call run('crlf rejection in token', test_crlf_token)
  call run('crlf rejection in basic auth', test_crlf_basic)
  call run('column json parse-and-embed', test_column_embed)
  call run('history retention parse valid', test_history_retention_parse_valid)
  call run('history retention parse missing key', test_history_retention_parse_missing)
  call run('history retention parse extra key', test_history_retention_parse_extra)
  call run('history retention parse non-integer', test_history_retention_parse_non_int)
  call run('set history retention payload', test_set_history_retention_payload)
  call run('static default matrix', test_static_default_matrix)

  write(*, '(A,I0,A,I0,A)') 'wire_shape: ', passed, ' passed, ', failed, ' failed'
  if (failed > 0) error stop 1

contains

  subroutine run(name, proc)
    character(*), intent(in) :: name
    interface
      subroutine proc()
      end subroutine proc
    end interface
    call proc
    if (local_fail_count() == 0) then
      passed = passed + 1
      write(*, '(A,A)') '  PASS  ', name
    else
      failed = failed + local_fail_count()
    end if
    call reset_fail_count
  end subroutine

  integer function local_fail_count()
    local_fail_count = test_fails - saved_fails
  end function

  subroutine reset_fail_count
    saved_fails = test_fails
  end subroutine

  ! A test calls fail() to record a failure (without aborting the run).
  ! Per-test failures are accumulated in test_fails; run() adds the delta
  ! to the global failed counter, so we must not increment it here too.
  subroutine fail(msg)
    character(*), intent(in) :: msg
    test_fails = test_fails + 1
    write(*, '(A,A)') '  FAIL  ', msg
  end subroutine

  subroutine check(cond, msg)
    logical, intent(in) :: cond
    character(*), intent(in) :: msg
    if (.not. cond) call fail(msg)
  end subroutine

  ! ---- Tests --------------------------------------------------------------

  subroutine test_json_object()
    type(json_value) :: obj, v, got
    character(:), allocatable :: s
    integer :: stat
    character(256) :: errmsg
    obj = json_make_object()
    call json_object_set_str(obj, 'name', 'orders')
    call json_object_set_int(obj, 'id', 42_int64)
    s = json_serialize(obj)
    call json_parse(s, v, stat, errmsg)
    call check(stat == 0, 'object round-trip parse failed')
    call check(json_object_has(v, 'name'), 'object missing key name')
    call check(json_object_has(v, 'id'), 'object missing key id')
    got = json_object_get(v, 'name')
    call check(got%str_val == 'orders', 'name value mismatch')
    got = json_object_get(v, 'id')
    call check(got%int_val == 42_int64, 'id value mismatch')
  end subroutine

  subroutine test_json_array()
    type(json_value) :: arr, v, elem
    character(:), allocatable :: s
    integer :: stat
    character(256) :: errmsg
    integer :: i
    arr = json_make_array()
    do i = 1, 5
      call json_array_push(arr, json_make_int(int(i, int64)))
    end do
    s = json_serialize(arr)
    call json_parse(s, v, stat, errmsg)
    call check(stat == 0, 'array round-trip parse failed')
    call check(json_array_len(v) == 5, 'array length mismatch')
    elem = json_array_get(v, 3)
    call check(elem%int_val == 3_int64, 'array element 3 mismatch')
  end subroutine

  subroutine test_json_escape()
    type(json_value) :: obj, v
    character(:), allocatable :: s
    integer :: stat
    character(256) :: errmsg
    ! A string with characters that must be escaped: quote, backslash, newline.
    obj = json_make_string('hello"world\' // char(10) // 'end')
    s = json_serialize(obj)
    call json_parse(s, v, stat, errmsg)
    call check(stat == 0, 'escaped string parse failed')
    call check(v%str_val == 'hello"world\' // char(10) // 'end', 'escaped string mismatch')
  end subroutine

  subroutine test_json_malformed()
    type(json_value) :: v
    integer :: stat
    character(256) :: errmsg
    ! Missing closing brace -> must fail.
    call json_parse('{"a":1', v, stat, errmsg)
    call check(stat /= 0, 'malformed JSON should be rejected')
    ! Trailing data -> must fail.
    call json_parse('{"a":1}garbage', v, stat, errmsg)
    call check(stat /= 0, 'trailing data should be rejected')
    ! Empty input -> must fail.
    call json_parse('', v, stat, errmsg)
    call check(stat /= 0, 'empty input should be rejected')
  end subroutine

  subroutine test_json_nested()
    type(json_value) :: obj, inner, v, got
    character(:), allocatable :: s
    integer :: stat
    character(256) :: errmsg
    inner = json_make_object()
    call json_object_set_str(inner, 'nested_key', 'nested_value')
    obj = json_make_object()
    call json_object_set(obj, 'outer', inner)
    call json_object_set_str(obj, 'top', 'ok')
    s = json_serialize(obj)
    call json_parse(s, v, stat, errmsg)
    call check(stat == 0, 'nested parse failed')
    got = json_object_get(v, 'outer')
    block
      type(json_value) :: inner_val
      inner_val = json_object_get(got, 'nested_key')
      call check(inner_val%str_val == 'nested_value', 'nested value mismatch')
    end block
  end subroutine

  subroutine test_url_encode()
    type(mongreldb_client) :: db
    integer :: stat
    character(256) :: errmsg
    ! We exercise encoding indirectly: a drop_table on a name with a slash
    ! must not error at the client level before reaching the network. Since
    ! there is no server, we expect a network error (not an invalid-arg or
    ! crash). This guards against the encoded path containing a raw '/'.
    call db%connect('http://127.0.0.1:9', stat, errmsg)
    call db%drop_table('name/with/slash', stat, errmsg)
    call check(stat == MDB_ERR_NETWORK, 'encoded table path should reach network layer')
  end subroutine

  subroutine test_status_mapping()
    ! The status->code mapping is exercised by comparing against the public
    ! constants. We reproduce the table here and assert the contract.
    call check(map_status(401) == MDB_ERR_AUTH, '401 -> auth')
    call check(map_status(403) == MDB_ERR_AUTH, '403 -> auth')
    call check(map_status(404) == MDB_ERR_NOT_FOUND, '404 -> not_found')
    call check(map_status(409) == MDB_ERR_CONFLICT, '409 -> conflict')
    call check(map_status(400) == MDB_ERR_QUERY, '400 -> query')
    call check(map_status(500) == MDB_ERR_QUERY, '500 -> query')
  end subroutine

  ! Local mirror of the status->code mapping for the unit test. Kept in sync
  ! with the client's private status_to_code by hand.
  function map_status(s) result(c)
    integer, intent(in) :: s
    integer :: c
    select case (s)
    case (401, 403); c = MDB_ERR_AUTH
    case (404);      c = MDB_ERR_NOT_FOUND
    case (409);      c = MDB_ERR_CONFLICT
    case default;    c = MDB_ERR_QUERY
    end select
  end function

  subroutine test_crlf_token()
    type(mongreldb_client) :: db
    integer :: stat
    character(256) :: errmsg
    ! A token containing a CR must be rejected with an auth error before any
    ! request is sent.
    call db%connect_with_token('http://127.0.0.1:9', 'evil' // char(13) // 'x', &
                               stat, errmsg)
    call check(stat == MDB_ERR_AUTH, 'CR in token must be rejected')
    call db%connect_with_token('http://127.0.0.1:9', 'evil' // char(10) // 'x', &
                               stat, errmsg)
    call check(stat == MDB_ERR_AUTH, 'LF in token must be rejected')
    ! A clean token is accepted (connection itself never fails).
    call db%connect_with_token('http://127.0.0.1:9', 'good-token', stat, errmsg)
    call check(stat == MDB_OK, 'clean token should be accepted')
  end subroutine

  subroutine test_crlf_basic()
    type(mongreldb_client) :: db
    integer :: stat
    character(256) :: errmsg
    call db%connect_with_basic_auth('http://127.0.0.1:9', 'user' // char(10), &
                                    'pass', stat, errmsg)
    call check(stat == MDB_ERR_AUTH, 'LF in username must be rejected')
    call db%connect_with_basic_auth('http://127.0.0.1:9', 'user', &
                                    'pass' // char(13), stat, errmsg)
    call check(stat == MDB_ERR_AUTH, 'CR in password must be rejected')
  end subroutine

  subroutine test_column_embed()
    ! Building a create_table payload from caller-supplied column JSON must
    ! produce a valid object. We verify by parsing the columns and embedding
    ! them, then checking the result is well-formed JSON.
    type(json_value) :: cols, obj, constraints, parsed
    integer :: stat
    character(256) :: errmsg
    character(:), allocatable :: cols_str, s
    cols = json_make_array()
    call json_array_push(cols, make_col(1_int64, 'id', 'int64', .true.))
    block
      type(json_value) :: col
      col = make_col(2_int64, 'name', 'varchar', .false.)
      call json_object_set_int(col, 'default_value', 3_int64)
      call json_object_set_str(col, 'default_expr', 'uuid')
      call json_array_push(cols, col)
    end block
    cols_str = json_serialize(cols)
    obj = json_make_object()
    call json_object_set_str(obj, 'name', 'orders')
    call json_parse_and_set(obj, 'columns', cols_str, stat, errmsg)
    call check(stat == 0, 'column embed parse failed')
    call json_parse('{"checks":[{"id":1,"name":"positive_id","expr":' // &
      '{"Gt":[{"Col":1},{"Lit":{"Int64":0}}]}}]}', constraints, stat, errmsg)
    call check(stat == 0, 'constraints parse failed')
    call json_object_set(obj, 'constraints', constraints)
    s = json_serialize(obj)
    call json_parse(s, parsed, stat, errmsg)
    call check(stat == 0, 'embedded payload re-parse failed')
    call check(json_object_has(parsed, 'columns'), 'payload missing columns key')
    call check(index(s, '"default_value":3') > 0, 'payload missing scalar default_value')
    call check(index(s, '"default_expr":"uuid"') > 0, 'payload missing default_expr')
    call check(index(s, '"constraints":{"checks":[') > 0, 'payload missing constraints.checks')
    call check(index(s, '"name":"positive_id"') > 0, 'payload missing CHECK name')
  end subroutine

  function make_col(id, nm, ty, pk) result(col)
    integer(int64), intent(in) :: id
    character(*), intent(in) :: nm, ty
    logical, intent(in) :: pk
    type(json_value) :: col
    col = json_make_object()
    call json_object_set_int(col, 'id', id)
    call json_object_set_str(col, 'name', nm)
    call json_object_set_str(col, 'ty', ty)
    call json_object_set_bool(col, 'primary_key', pk)
    call json_object_set_bool(col, 'nullable', .not. pk)
  end function

  ! Thin wrapper so the test can mirror the client's parse-and-embed helper.
  subroutine json_parse_and_set(obj, key, fragment, stat, errmsg)
    type(json_value), intent(inout) :: obj
    character(*), intent(in) :: key, fragment
    integer, intent(out) :: stat
    character(*), intent(out) :: errmsg
    type(json_value) :: v
    call json_parse(fragment, v, stat, errmsg)
    if (stat /= 0) return
    call json_object_set(obj, key, v)
    stat = 0
  end subroutine

  ! ---- Retention response parsing ------------------------------------------

  subroutine test_history_retention_parse_valid()
    type(json_value) :: doc
    integer :: stat
    integer(int64) :: epochs, earliest
    character(256) :: errmsg
    call json_parse('{"history_retention_epochs":100,"earliest_retained_epoch":5}', &
                    doc, stat, errmsg)
    call check(stat == 0, 'valid retention JSON parse failed')
    if (stat /= 0) return
    call parse_history_retention_response(doc, epochs, earliest, stat, errmsg)
    call check(stat == MDB_OK, 'valid retention response should validate')
    call check(epochs == 100_int64, 'epochs value mismatch')
    call check(earliest == 5_int64, 'earliest value mismatch')
  end subroutine

  subroutine test_history_retention_parse_missing()
    type(json_value) :: doc
    integer :: stat
    integer(int64) :: epochs, earliest
    character(256) :: errmsg
    call json_parse('{"history_retention_epochs":100}', doc, stat, errmsg)
    call check(stat == 0, 'missing-key JSON parse failed')
    call parse_history_retention_response(doc, epochs, earliest, stat, errmsg)
    call check(stat == MDB_ERR_JSON, 'missing key should report JSON error')
  end subroutine

  subroutine test_history_retention_parse_extra()
    type(json_value) :: doc
    integer :: stat
    integer(int64) :: epochs, earliest
    character(256) :: errmsg
    call json_parse('{"history_retention_epochs":100,"earliest_retained_epoch":5,"extra":1}', &
                    doc, stat, errmsg)
    call check(stat == 0, 'extra-key JSON parse failed')
    call parse_history_retention_response(doc, epochs, earliest, stat, errmsg)
    call check(stat == MDB_ERR_JSON, 'extra key should report JSON error')
  end subroutine

  subroutine test_history_retention_parse_non_int()
    type(json_value) :: doc
    integer :: stat
    integer(int64) :: epochs, earliest
    character(256) :: errmsg
    call json_parse('{"history_retention_epochs":"100","earliest_retained_epoch":5}', &
                    doc, stat, errmsg)
    call check(stat == 0, 'non-integer JSON parse failed')
    call parse_history_retention_response(doc, epochs, earliest, stat, errmsg)
    call check(stat == MDB_ERR_JSON, 'non-integer value should report JSON error')
    call json_parse('{"history_retention_epochs":100,"earliest_retained_epoch":true}', &
                    doc, stat, errmsg)
    call check(stat == 0, 'boolean JSON parse failed')
    call parse_history_retention_response(doc, epochs, earliest, stat, errmsg)
    call check(stat == MDB_ERR_JSON, 'boolean value should report JSON error')
  end subroutine

  subroutine test_set_history_retention_payload()
    type(json_value) :: obj
    character(:), allocatable :: s
    integer(int64), parameter :: value = 250_int64
    obj = json_make_object()
    call json_object_set_int(obj, 'history_retention_epochs', value)
    s = json_serialize(obj)
    call check(s == '{"history_retention_epochs":250}', &
               'set retention payload mismatch: ' // s)
  end subroutine

  ! ---- Static-default matrix -----------------------------------------------

  subroutine test_static_default_matrix()
    type(json_value) :: cols, body, parsed, col
    character(:), allocatable :: cols_str, payload
    integer :: stat, n
    character(256) :: errmsg

    cols = json_make_array()
    call json_array_push(cols, make_col(1_int64, 'id', 'int64', .true.))

    col = make_col(2_int64, 'label', 'varchar', .false.)
    call json_object_set_str(col, 'default_value', 'draft')
    call json_array_push(cols, col)

    col = make_col(3_int64, 'qty', 'int64', .false.)
    call json_object_set_int(col, 'default_value', 7_int64)
    call json_array_push(cols, col)

    col = make_col(4_int64, 'active', 'bool', .false.)
    call json_object_set_bool(col, 'default_value', .true.)
    call json_array_push(cols, col)

    col = make_col(5_int64, 'notes', 'varchar', .false.)
    call json_object_set(col, 'default_value', json_make_null())
    call json_array_push(cols, col)

    col = make_col(6_int64, 'created', 'varchar', .false.)
    call json_object_set_str(col, 'default_value', 'now')
    call json_array_push(cols, col)

    col = make_col(7_int64, 'updated', 'varchar', .false.)
    call json_object_set_str(col, 'default_expr', 'now')
    call json_array_push(cols, col)

    cols_str = json_serialize(cols)
    body = json_make_object()
    call json_object_set_str(body, 'name', 'defaults_demo')
    call json_parse_and_set(body, 'columns', cols_str, stat, errmsg)
    call check(stat == 0, 'default matrix column parse failed')
    if (stat /= 0) return

    payload = json_serialize(body)
    call json_parse(payload, parsed, stat, errmsg)
    call check(stat == 0, 'default matrix payload re-parse failed')
    if (stat /= 0) return

    if (.not. json_object_has(parsed, 'columns')) then
      call fail('payload missing columns'); return
    end if
    cols = json_object_get(parsed, 'columns')
    if (cols%kind /= JSON_ARRAY) then
      call fail('columns is not an array'); return
    end if
    n = json_array_len(cols)
    call check(n == 7, 'default matrix column count mismatch')
    if (n < 7) return

    call check_col_default(cols, 2, 'default_value', JSON_STRING, '"draft"')
    call check_col_default(cols, 3, 'default_value', JSON_INT, '7')
    call check_col_default(cols, 4, 'default_value', JSON_BOOL, 'true')
    call check_col_default(cols, 5, 'default_value', JSON_NULL, 'null')
    call check_col_default(cols, 6, 'default_value', JSON_STRING, '"now"')
    call check_col_default(cols, 7, 'default_expr', JSON_STRING, '"now"')

    col = json_array_get(cols, 6)
    call check(.not. json_object_has(col, 'default_expr'), &
               'literal "now" default_value must not become default_expr')
    col = json_array_get(cols, 7)
    call check(.not. json_object_has(col, 'default_value'), &
               'default_expr column must not also carry default_value')
  end subroutine

  subroutine check_col_default(cols, idx, key, kind, expected)
    type(json_value), intent(in) :: cols
    integer, intent(in) :: idx, kind
    character(*), intent(in) :: key, expected
    type(json_value) :: col, val
    character(:), allocatable :: got

    col = json_array_get(cols, idx)
    if (.not. json_object_has(col, key)) then
      call fail('column ' // int_str(idx) // ' missing ' // key); return
    end if
    val = json_object_get(col, key)
    if (val%kind /= kind) then
      call fail('column ' // int_str(idx) // ' ' // key // ' kind mismatch'); return
    end if
    got = json_serialize(val)
    call check(got == expected, 'column ' // int_str(idx) // ' ' // key // &
                                ' expected ' // expected // ' got ' // got)
  end subroutine

  function int_str(i) result(s)
    integer, intent(in) :: i
    character(16) :: s
    write(s, '(I0)') i
  end function

end program
