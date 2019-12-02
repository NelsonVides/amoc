%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
%% Licensed under the Apache License, Version 2.0 (see LICENSE file)
%%==============================================================================
-module(amoc_dist).

-export([do/3,
         add/1,
         add/2,
         remove/2,
         remove/3]).

-compile({no_auto_import, [ceil/1]}).
%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------
-spec do(amoc:scenario(), non_neg_integer(), amoc_config_scenario:config()) ->
    {ok, any()} | {error, any()}.
do(Scenario, Count, Settings) ->
    case {prepare_cluster(Scenario, Settings), Count} of
        {{ok, _}, 0} -> {ok, no_users};
        {{ok, _}, Count} -> add(Count);
        {Error, _} -> Error
    end.

-spec add(pos_integer()) -> {ok, any()}| {error, any()}.
add(Count) ->
    add(Count, amoc_cluster:slave_nodes()).

-spec add(pos_integer(), [node()]) -> {ok, any()} | {error, any()}.
add(Count, Nodes) when is_integer(Count), Count > 0 ->
    case check_nodes(Nodes) of
        ok -> add_users(Count, Nodes);
        Error -> Error
    end.

-spec remove(pos_integer(), boolean()) -> {ok, any()} | {error, any()}.
remove(Count, ForceRemove) ->
    remove(Count, ForceRemove, amoc_cluster:slave_nodes()).

-spec remove(pos_integer(), boolean(), [node()]) -> {ok, any()} | {error, any()}.
remove(Count, ForceRemove, Nodes) when is_integer(Count), Count > 0 ->
    case check_nodes(Nodes) of
        ok -> remove_users(Count, ForceRemove, Nodes);
        Error -> Error
    end.

%% ------------------------------------------------------------------
%% Local functions
%% ------------------------------------------------------------------
-spec get_param(any()) -> {ok, any()} | undefined.
get_param(Key) ->
    try persistent_term:get({amoc_dist, Key}) of
        Value -> {ok, Value}
    catch
        error:badarg -> undefined
    end.

-spec set_param(any(), any()) -> ok.
set_param(Key, Value) ->
    persistent_term:put({amoc_dist, Key}, Value).

-spec check_nodes([node()]) -> ok | {error, any()}.
check_nodes(Nodes) ->
    SlaveNodes = amoc_cluster:slave_nodes(),
    MasterNode = amoc_cluster:master_node(),
    case {Nodes -- SlaveNodes, Nodes, node()} of
        {[], [_ | _], MasterNode} ->
            %% running on the master node with the proper non-empty Nodes list
            ok;
        {[], [], MasterNode} ->
            %% Nodes list is empty
            {error, empty_nodes_list};
        {BadNodes, _, MasterNode} ->
            %% non-slave nodes in the list
            {error, {bad_nodes, BadNodes}};
        {_, _, _} ->
            {error, not_a_master}
    end.

-spec prepare_cluster(amoc:scenario(), amoc_config_scenario:config()) -> {ok, any()} | {error, any()}.
prepare_cluster(Scenario, Settings) ->
    case setup_master_node() of
        ok ->
            set_param(scenario, Scenario),
            set_param(settings, Settings),
            set_param(last_id, 0),
            setup_cluster();
        Error -> Error
    end.

-spec setup_master_node() -> ok | {error, any()}.
setup_master_node() ->
    case {amoc_cluster:set_master_node(node()), get_param(scenario)} of
        {ok, undefined} ->
            amoc_controller:disable();
        {ok, AnotherScenario} ->
            {error, {scenario_is_running, AnotherScenario}};
        Error -> Error
    end.

-spec setup_cluster() -> {ok, any()} | {error, any()}.
setup_cluster() ->
    case amoc_cluster:on_new_connection(fun setup_slave_node/1) of
        {ok, SlaveNodes} ->
            Result = [{Node, amoc_cluster:set_master_node(Node)} || Node <- SlaveNodes],
            maybe_error(Result);
        Error -> Error
    end.

-spec setup_slave_node(node()) -> ok | {error, any()} | {badrpc, any()}.
setup_slave_node(Node) ->
    case propagate_uploaded_modules(Node) of
        {ok, _} ->
            {ok, Scenario} = get_param(scenario),
            {ok, Settings} = get_param(settings),
            rpc:call(Node, amoc_controller, start_scenario, [Scenario, Settings]);
        Error -> Error
    end.

-spec propagate_uploaded_modules(node()) -> {ok, any()} | {error, any()}.
propagate_uploaded_modules(Node) ->
    UploadedModules = ets:match(amoc_scenarios, {'$1', '_', {uploaded, '$2'}}),
    Result = [{Module, rpc:call(Node, amoc_scenario, install_scenario, Args)} ||
                 [Module, _] = Args <- UploadedModules],
    maybe_error(Result).

-spec add_users(pos_integer(), [node()]) -> {ok, any()} | {error, any()}.
add_users(Count, Nodes) ->
    {ok, LastId} = get_param(last_id),
    set_param(last_id, LastId + Count),
    Result = add_users([], LastId, Count, Nodes),
    maybe_error(Result).

-spec add_users([{node(), any()}], non_neg_integer(), non_neg_integer(), [node()]) ->
    [{node(), any()}].
add_users(Result, _, 0, []) -> Result;
add_users(Result, LastId, Count, [Node | T] = Nodes) ->
    case Count div length(Nodes) of
        0 ->
            add_users([{Node, {ok, node_skipped}} | Result], LastId, Count, T);
        N ->
            Ret = rpc:call(Node, amoc_controller, add_users, [LastId + 1, LastId + N]),
            add_users([{Node, Ret} | Result], LastId + N, Count - N, T)
    end.

-spec remove_users(pos_integer(), boolean(), [node()]) -> {ok, any()} | {error, any()}.
remove_users(Count, ForceRemove, Nodes) ->
    Result = remove_users([], Count, ForceRemove, Nodes),
    maybe_error(Result).

-spec remove_users([{node(), any()}], non_neg_integer(), boolean(), [node()]) ->
    [{node(), any()}].
remove_users(Result, 0, _, []) -> Result;
remove_users(Result, Count, ForceRemove, [Node | T] = Nodes) ->
    case Count div length(Nodes) of
        0 ->
            remove_users([{Node, {ok, node_skipped}} | Result], Count, ForceRemove, T);
        N ->
            Ret = rpc:call(Node, amoc_controller, remove_users, [N, ForceRemove]),
            remove_users([{Node, Ret} | Result], Count - N, ForceRemove, T)
    end.

-spec maybe_error([{any(), any()}]) -> {ok, any()} | {error, any()}.
maybe_error(Result) ->
    ValuesAndErrors = lists:foldl(
        fun({Tag, {ok, Value}}, {OkValues, Errors}) ->
            {[{Tag, Value} | OkValues], Errors};
           ({Tag, ok}, {OkValues, Errors}) ->
               {[Tag | OkValues], Errors};
           ({Tag, {badrpc, Reason}}, {OkValues, Errors}) ->
               {OkValues, [{Tag, {badrpc, Reason}} | Errors]};
           ({Tag, {error, Reason}}, {OkValues, Errors}) ->
               {OkValues, [{Tag, Reason} | Errors]};
           ({Tag, InvalidRetValue}, {OkValues, Errors}) ->
               {OkValues, [{Tag, {invalid_ret_value, InvalidRetValue}} | Errors]}
        end, {[], []}, Result),
    case ValuesAndErrors of
        {OkValues, []} -> {ok, OkValues};
        {_, Errors} -> {error, Errors}
    end.
