% This eunit module tests below APIs:
% find_coordinator (txn)
% init_producer_id,
% add_partitions_to_txn,
% add_offsets_to_txn,
% end_txn,
% txn_offset_commit,

-module(kpro_txn_tests).

-include_lib("eunit/include/eunit.hrl").
-include("kpro_private.hrl").

-define(TIMEOUT, 5000).

%% this is just an attempt to warm-up kafka
warm_up_test() ->
  {ok, Versions} = with_connection(fun(Pid) -> kpro:get_api_versions(Pid) end),
  {_MinProduceVsn, MaxProduceVsn} = maps:get(produce, Versions),
  case MaxProduceVsn >= ?MIN_MAGIC_2_PRODUCE_API_VSN of
    true ->
      TxnId = make_transactional_id(),
      % find_coordinator (txn)
      {ok, Conn} =
        case connect_coordinator(TxnId) of
          {ok, Success} -> {ok, Success};
          {error, _Failure} ->
            % kafka will have to create the internal topic for
            % transaction state logs when it receives
            % `find_coordinator' request for the fist time.
            % This connect call may fail with a 'coordinator_not_available'
            % reason, here we add a delayed retry to hope for the best
            timer:sleep(2000),
            connect_coordinator(TxnId)
        end,
      _ = kpro:txn_init_ctx(Conn, TxnId),
      ok = kpro:close_connection(Conn);
    false ->
      io:format(user, " skipped (vsn = ~p)", [MaxProduceVsn])
  end.

%% basic test of begin -> write -> commit
txn_produce_test() ->
  {ok, Versions} = with_connection(fun(Pid) -> kpro:get_api_versions(Pid) end),
  {MinProduceVsn, MaxProduceVsn} = maps:get(produce, Versions),
  {_, FetchVsn} = maps:get(fetch, Versions),
  case MaxProduceVsn >= ?MIN_MAGIC_2_PRODUCE_API_VSN of
    true -> test_txn_produce(rand(MinProduceVsn, MaxProduceVsn), FetchVsn);
    false -> io:format(user, " skipped (vsn = ~p)", [MaxProduceVsn])
  end.

test_txn_produce(ProduceVsn, FetchVsn) ->
  Topic = topic(),
  Partition = partition(),
  FetchReqFun =
    fun(Offset, IsolationLevel) ->
        kpro_req_lib:fetch(FetchVsn, Topic, Partition,
                           Offset, 500, 0, 10000, IsolationLevel)
    end,
  TxnId = make_transactional_id(),
  % find_coordinator (txn)
  {ok, Conn} = connect_coordinator(TxnId),
  % init_producer_id
  {ok, TxnCtx} = kpro:txn_init_ctx(Conn, TxnId),
  % add_partitions_to_txn
  ok = kpro:txn_send_partitions(TxnCtx, [{Topic, Partition}]),
  % produce
  {_Seqno, Batches} = produce_messages(ProduceVsn, TxnCtx),
  [{BaseOffset, _} | _] = Batches,
  Messages = lists:append([Msgs || {_, Msgs} <- Batches]),
  % fetch (with isolation_level = read_committed) expect no message
  ok = fetch_and_verify(FetchReqFun, BaseOffset, [], read_committed),
  % fetch (with isolation_level = read_uncommitted)
  ok = fetch_and_verify(FetchReqFun, BaseOffset, Messages, read_uncommitted),
  % end_txn (commit)
  ok = kpro:txn_commit(TxnCtx),
  % fetch (with isolation_level = read_committed)
  ok = fetch_and_verify(FetchReqFun, BaseOffset, Messages, read_committed),
  ok = kpro:close_connection(Conn),
  ok.

%% basic test of begin -> read (fetch) write -> commit;
%% commit implies 1) commit fetched offset, 2) commit produced messages
txn_fetch_produce_test() ->
  {ok, Versions} = with_connection(fun(Pid) -> kpro:get_api_versions(Pid) end),
  {MinProduceVsn, MaxProduceVsn} = maps:get(produce, Versions),
  ProduceVsn = rand(MinProduceVsn, MaxProduceVsn),
  {_, FetchVsn} = maps:get(fetch, Versions),
  case MaxProduceVsn >= ?MIN_MAGIC_2_PRODUCE_API_VSN of
    true -> test_txn_fetch_produce_test(ProduceVsn, FetchVsn);
    false -> io:format(user, " skipped (vsn = ~p)", [MaxProduceVsn])
  end.

test_txn_fetch_produce_test(ProduceVsn, FetchVsn) ->
  Topic = topic(),
  Partition = partition(),
  FetchReqFun =
    fun(Offset, read_committed) -> % this test case tests read_committed only
        kpro_req_lib:fetch(FetchVsn, Topic, Partition,
                           Offset, 500, 0, 10000, read_committed)
    end,
  GroupId = make_group_id(),
  {ok, GroupConn} = connect_group_coordinator(GroupId),
  TxnId = make_transactional_id(),
  % find_coordinator (txn)
  {ok, Conn} = connect_coordinator(TxnId),
  % init_producer_id
  {ok, TxnCtx} = kpro:txn_init_ctx(Conn, TxnId),
  % add_partitions_to_txn
  ok = kpro:txn_send_partitions(TxnCtx, [{Topic, Partition}]),
  % produce
  {_Seqno, Batches} = produce_messages(ProduceVsn, TxnCtx),
  [{BaseOffset, _} | _] = Batches,
  Messages = lists:append([Msgs || {_, Msgs} <- Batches]),
  % add_offsets_to_txn
  ok = kpro:txn_send_cg(TxnCtx, GroupId),
  % txn_offset_commit
  ok = kpro:txn_offset_commit(GroupConn, GroupId, TxnCtx,
                              #{{Topic, Partition} => 42}),
  ok = kpro:txn_offset_commit(GroupConn, GroupId, TxnCtx,
                              #{{Topic, Partition} => {43, <<"foo">>}}),
  % end_txn (commit)
  ok = kpro:txn_commit(TxnCtx),
  % fetch (with isolation_level = read_committed)
  ok = fetch_and_verify(FetchReqFun, BaseOffset, Messages),
  ok = kpro:close_connection(Conn),
  ok.

%% test two transactions for the same transactional producer
%% without transaction context re-init
txn_produce_2_tx_test() ->
  {ok, Versions} = with_connection(fun(Pid) -> kpro:get_api_versions(Pid) end),
  {MinProduceVsn, MaxProduceVsn} = maps:get(produce, Versions),
  {_, FetchVsn} = maps:get(fetch, Versions),
  case MaxProduceVsn >= ?MIN_MAGIC_2_PRODUCE_API_VSN of
    true -> test_txn_produce_2(rand(MinProduceVsn, MaxProduceVsn), FetchVsn);
    false -> io:format(user, " skipped (vsn = ~p)", [MaxProduceVsn])
  end.

test_txn_produce_2(ProduceVsn, FetchVsn) ->
  Topic = topic(),
  Partition = partition(),
  FetchReqFun =
    fun(Offset, IsolationLevel) ->
        kpro_req_lib:fetch(FetchVsn, Topic, Partition,
                           Offset, 500, 0, 10000, IsolationLevel)
    end,
  TxnId = make_transactional_id(),
  % find_coordinator (txn)
  {ok, Conn} = connect_coordinator(TxnId),
  % init_producer_id
  {ok, TxnCtx} = kpro:txn_init_ctx(Conn, TxnId),

  TxnFun =
    fun(Seqno) ->
        ok = kpro:txn_send_partitions(TxnCtx, [{Topic, Partition}]),
        {NextSeqno, Batches} = produce_messages(ProduceVsn, TxnCtx, Seqno),
        [{BaseOffset, _} | _] = Batches,
        Messages = lists:append([Msgs || {_, Msgs} <- Batches]),
        ok = kpro:txn_commit(TxnCtx),
        ok = fetch_and_verify(FetchReqFun, BaseOffset, Messages),
        NextSeqno
    end,
  Seqno1 = TxnFun(0),
  _Seqno2 = TxnFun(Seqno1),
  ok = kpro:close_connection(Conn),
  ok.


%%%_* Helpers ==================================================================

fetch_and_verify(FetchReqFun, BaseOffset, ExpectedMessages) ->
  fetch_and_verify(FetchReqFun, BaseOffset, ExpectedMessages, read_committed).

fetch_and_verify(FetchReqFun, BaseOffset, ExpectedMessages, IsolationLevel) ->
  with_connection_to_partition_leader(
    fun(Connection) ->
        FetchAndVerif =
          fun(Offset, Exp) ->
              Req = FetchReqFun(Offset, IsolationLevel),
              {ok, Rsp} = kpro:request_sync(Connection, Req, ?TIMEOUT),
              #{batches := Batches0} = kpro_rsp_lib:parse(Rsp),
              Messages = lists:append([Msgs || {Meta, Msgs} <- Batches0,
                                       not kpro_batch:is_control(Meta)]),
              verify_messages(Offset, Messages, Exp)
          end,
        fetch_and_verify(FetchAndVerif, {BaseOffset, ExpectedMessages})
    end).

fetch_and_verify(_FetchAndVerif, done) -> ok;
fetch_and_verify(FetchAndVerif, {Offset, ExpectedMessages}) ->
  Next = FetchAndVerif(Offset, ExpectedMessages),
  fetch_and_verify(FetchAndVerif, Next).

%% returns 'done' when done verification
%% otherwise return next offset and remaining expectations
verify_messages(_Offset, [], []) -> done;
verify_messages(Offset,
                [#kafka_message{ offset = Offset
                               , key = Key
                               , value = Value
                               } | Messages],
                [#{ key := Key
                  , value := Value
                  } | ExpectedMessages]) ->
  verify_messages(Offset + 1, Messages, ExpectedMessages);
verify_messages(Offset, [], ExpectedMessages) ->
  {Offset, ExpectedMessages}.

produce_messages(ProduceVsn, TxnCtx) ->
  produce_messages(ProduceVsn, TxnCtx, _Seqno = 0).

produce_messages(ProduceVsn, TxnCtx, Seqno0) ->
  Topic = topic(),
  Partition = partition(),
  ReqFun =
    fun(Seqno, Batch) ->
        Opts = #{txn_ctx => TxnCtx, first_sequence => Seqno},
        kpro_req_lib:produce(ProduceVsn, Topic, Partition, Batch, Opts)
    end,
  Batch0 = make_random_batch(),
  Req0 = ReqFun(Seqno0, Batch0),
  Seqno1 = Seqno0 + length(Batch0),
  Batch1 = make_random_batch(),
  Seqno  = Seqno1 + length(Batch1),
  Req1 = ReqFun(Seqno1, Batch1),
  with_connection_to_partition_leader(
    fun(Connection) ->
        {ok, Rsp0} = kpro:request_sync(Connection, Req0, ?TIMEOUT),
        #{ error_code := no_error
         , base_offset := Offset0
         } = kpro_rsp_lib:parse(Rsp0),
        {ok, Rsp1} = kpro:request_sync(Connection, Req1, ?TIMEOUT),
        #{ error_code := no_error
         , base_offset := Offset1
         } = kpro_rsp_lib:parse(Rsp1),
        {Seqno, [{Offset0, Batch0}, {Offset1, Batch1}]}
    end).

with_connection_to_partition_leader(Fun) ->
  ConnFun =
    fun(Endpoints, Cfg) ->
        kpro:connect_partition_leader(Endpoints, Cfg, topic(), partition())
    end,
  with_connection(ConnFun, Fun).

with_connection(F) ->
  kpro_test_lib:with_connection(F).

with_connection(ConnectF, F) ->
  kpro_test_lib:with_connection(ConnectF, F).

topic() -> kpro_test_lib:get_topic().

partition() -> 0.

make_random_batch() ->
  N = rand(10),
  [#{ key => integer_to_binary(I)
    , value => term_to_binary(os:system_time())
    } || I <- lists:seq(0, N)
  ].

connect_coordinator(ProducerId) ->
  Cluster = kpro_test_lib:get_endpoints(ssl),
  ConnCfg = kpro_test_lib:connection_config(ssl),
  Args = #{type => txn, id => ProducerId},
  kpro:connect_coordinator(Cluster, ConnCfg, Args).

connect_group_coordinator(GroupId) ->
  Cluster = kpro_test_lib:get_endpoints(plaintext),
  ConnCfg = kpro_test_lib:connection_config(plaintext),
  Args = #{type => group, id => GroupId},
  kpro:connect_coordinator(Cluster, ConnCfg, Args).

%% Make a random transactional id, so test cases would not interfere each other.
make_transactional_id() ->
  bin([atom_to_list(?MODULE), "-txn-", bin(rand())]).

make_group_id() ->
  bin([atom_to_list(?MODULE), "-grp-", bin(rand())]).

rand() -> rand:uniform(1000000).

rand(N) -> rand() rem N.

rand(Min, Max) ->
  Min + rand(Max - Min + 1).

bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Str) -> iolist_to_binary(Str).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
