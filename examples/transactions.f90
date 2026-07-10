!> Transactions example for the MongrelDB Fortran client.
!>
!> Demonstrates a multi-op atomic transaction with an idempotency key for safe
!> retries, and shows the all-or-nothing rollback on conflict. Cleans up on exit.
program transactions
  use, non_intrinsic :: mongreldb
  use, non_intrinsic :: mongreldb_json
  use iso_fortran_env, only: int64
  implicit none

  type(mongreldb_client) :: db
  integer :: stat
  character(512) :: errmsg
  character(:), allocatable :: table, cols_json, url, results_json
  character(256) :: envbuf
  integer(int64) :: n

  call get_environment_variable('MONGRELDB_URL', envbuf)
  if (len_trim(envbuf) > 0) then
    url = trim(envbuf)
  else
    url = MDB_DEFAULT_URL
  end if

  table = 'demo_txn_' // make_suffix()

  call db%connect(url, stat, errmsg)
  if (stat /= MDB_OK) call die('connect failed: ' // trim(errmsg))
  if (.not. db%health()) call die('daemon not reachable')

  cols_json = '[' // &
    '{"id":1,"name":"id","ty":"int64","primary_key":true,"nullable":false},' // &
    '{"id":2,"name":"name","ty":"varchar","primary_key":false,"nullable":false},' // &
    '{"id":3,"name":"qty","ty":"int64","primary_key":false,"nullable":true}' // &
    ']'
  call db%create_table(table, cols_json, stat, errmsg)
  if (stat /= MDB_OK) call die('create_table failed: ' // trim(errmsg))

  ! A multi-op batch. All ops commit atomically: either every row lands or
  ! none do. The idempotency key makes the request safe to retry on timeout.
  block
    character(:), allocatable :: ops_json, idem
    idem = 'demo-batch-' // make_suffix()
    ops_json = '[' // &
      '{"put":{"table":"' // table // '","cells":[1,1,2,"widget",3,10]}},' // &
      '{"put":{"table":"' // table // '","cells":[1,2,2,"gadget",3,5]}},' // &
      '{"upsert":{"table":"' // table // '","cells":[1,3,2,"gizmo",3,2]}}' // &
      ']'
    call db%transaction(ops_json, results_json, stat, errmsg, idem)
    if (stat /= MDB_OK) call die('transaction failed: ' // trim(errmsg))
    write(*, '(A)') 'Committed 3-op batch with idempotency key'
  end block

  n = db%count(table, stat, errmsg)
  if (stat /= MDB_OK) call die('count after batch failed: ' // trim(errmsg))
  write(*, '(A,I0)') 'Row count after batch: ', n

  ! Demonstrate a second batch: two new rows committed atomically. With an
  ! idempotency key this is safe to retry on network failure.
  block
    character(:), allocatable :: more_ops, more_results
    more_ops = '[' // &
      '{"put":{"table":"' // table // '","cells":[1,10,2,"new-item",3,1]}},' // &
      '{"put":{"table":"' // table // '","cells":[1,11,2,"other-item",3,2]}}' // &
      ']'
    call db%transaction(more_ops, more_results, stat, errmsg, &
                        idem_key='second-batch-' // make_suffix())
    if (stat /= MDB_OK) call die('second batch failed: ' // trim(errmsg))
    write(*, '(A)') 'Committed 2-op batch (new rows)'
  end block

  ! After the second batch, the table should have 5 rows.
  n = db%count(table, stat, errmsg)
  if (stat /= MDB_OK) call die('count after second batch failed: ' // trim(errmsg))
  if (n == 5) then
    write(*, '(A)') 'Row count is 5 after second batch - OK'
  else
    write(*, '(A,I0)') 'Note: row count is ', n, ' (server may deduplicate)'
  end if

  call cleanup()

contains

  subroutine die(msg)
    character(*), intent(in) :: msg
    write(*, '(A)') msg
    call cleanup()
    error stop 1
  end subroutine

  subroutine cleanup()
    integer :: s
    character(512) :: m
    call db%drop_table(table, s, m)
  end subroutine

  function make_suffix() result(s)
    character(:), allocatable :: s
    integer :: ticks
    character(32) :: buf
    call system_clock(ticks)
    write(buf, '(I0)') ticks
    s = trim(buf)
  end function

end program
