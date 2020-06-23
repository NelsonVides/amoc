-module(amoc_api_status_handler_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([returns_up_when_amoc_up_online/1,
         returns_down_when_api_up_and_amoc_down_online/1]).

-define(PATH, "/status").

all() ->
    [returns_up_when_amoc_up_online,
     returns_down_when_api_up_and_amoc_down_online].

init_per_testcase(_, Config) ->
    amoc_api_helper:start_amoc(),
    Config.

end_per_testcase(_, _Config) ->
    amoc_api_helper:stop_amoc().

returns_up_when_amoc_up_online(_Config) ->
    %% when
    {CodeHttp, Body} = amoc_api_helper:get(?PATH),
    %% then
    ?assertEqual(200, CodeHttp),
    ?assertMatch({[{<<"node_status">>, <<"up">>}]}, Body).

returns_down_when_api_up_and_amoc_down_online(_Config) ->
    %% given
    given_amoc_app_is_down(),
    %% when
    {CodeHttp, Body} = amoc_api_helper:get(?PATH),
    %% then
    ?assertEqual(200, CodeHttp),
    ?assertMatch({[{<<"node_status">>, <<"down">>}]}, Body).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% HELPERS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec given_amoc_app_is_down() -> any().
given_amoc_app_is_down() ->
    application:stop(amoc).
