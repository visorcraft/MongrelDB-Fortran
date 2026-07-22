!> Offline unit test: structural HLC parse from query-status JSON (AC1).
program durable_hlc_test
  use mongreldb
  use iso_fortran_env, only: int64
  implicit none
  type(mdb_commit_hlc) :: hlc
  character(:), allocatable :: ser
  integer :: stat, fails
  character(*), parameter :: fixture = &
    '{"query_id":"abcdefabcdefabcdefabcdefabcdefab","status":"committed",' // &
    '"state":"completed","server_state":"completed","committed":true,' // &
    '"last_commit_hlc":{"physical_micros":1700000000000000,"logical":3,' // &
    '"node_tiebreaker":7},"outcome":{"committed":true,"committed_statements":1,' // &
    '"last_commit_epoch":17,"last_commit_hlc":{"physical_micros":1700000000000000,' // &
    '"logical":3,"node_tiebreaker":7},"serialization":"succeeded",' // &
    '"serialization_state":"succeeded"},"durable":{"committed":true,' // &
    '"committed_statements":1,"last_commit_epoch":17,' // &
    '"last_commit_hlc":{"physical_micros":1700000000000000,"logical":3,' // &
    '"node_tiebreaker":7},"serialization":"succeeded",' // &
    '"serialization_state":"succeeded"}}'
  fails = 0
  call query_status_commit_hlc(fixture, hlc, stat)
  if (stat /= MDB_OK) then
    print *, 'FAIL: query_status_commit_hlc stat=', stat
    fails = fails + 1
  end if
  if (.not. hlc%present) then
    print *, 'FAIL: hlc not present'
    fails = fails + 1
  end if
  if (hlc%physical_micros /= 1700000000000000_int64) then
    print *, 'FAIL: physical_micros=', hlc%physical_micros
    fails = fails + 1
  end if
  if (hlc%logical /= 3) then
    print *, 'FAIL: logical=', hlc%logical
    fails = fails + 1
  end if
  if (hlc%node_tiebreaker /= 7) then
    print *, 'FAIL: node_tiebreaker=', hlc%node_tiebreaker
    fails = fails + 1
  end if
  call query_status_serialization_state(fixture, ser, stat)
  if (stat /= MDB_OK .or. ser /= 'succeeded') then
    print *, 'FAIL: serialization_state=', ser
    fails = fails + 1
  end if
  if (fails == 0) then
    print *, 'OK durable_hlc_test (6 checks)'
  else
    print *, 'FAILED', fails, 'checks'
    stop 1
  end if
end program
