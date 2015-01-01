%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Advertisement counter, OR-Set example.

-module(lasp_adcounter_orset_test).
-author("Christopher Meiklejohn <cmeiklejohn@basho.com>").

-export([test/0,
         client/2,
         server/2]).

-ifdef(TEST).

-export([confirm/0]).

-define(HARNESS, (rt_config:get(rt_harness))).

-include_lib("eunit/include/eunit.hrl").

confirm() ->
    [Nodes] = rt:build_clusters([1]),
    lager:info("Nodes: ~p", [Nodes]),
    Node = hd(Nodes),

    lager:info("Remotely loading code on node ~p", [Node]),
    ok = lasp_test_helpers:load(Nodes),
    lager:info("Remote code loading complete."),

    ok = lasp_test_helpers:wait_for_cluster(Nodes),

    lager:info("Remotely executing the test."),
    Result = rpc:call(Node, ?MODULE, test, []),
    ?assertEqual(ok, Result),

    pass.

-endif.

test() ->
    %% Generate an OR-set for tracking advertisement counters.
    {ok, Ads} = lasp:declare(riak_dt_orset),

    %% Build an advertisement counter, and add it to the set.
    lists:foldl(fun(_, _Ads) ->
                {ok, Id} = lasp:declare(riak_dt_gcounter),
                {ok, _, _} = lasp:update(Ads, {add, Id}),
                Ads
                end, Ads, lists:seq(1,5)),

    %% Generate a OR-set for tracking clients.
    {ok, Clients} = lasp:declare(riak_dt_orset),

    %% Each client takes the full list of ads when it starts, and reads
    %% from the variable store.
    lists:foldl(fun(Id, _Clients) ->
                ClientPid = spawn(?MODULE, client, [Id, Ads]),
                {ok, _, _} = lasp:update(Clients, {add, ClientPid}),
                Clients
                end, Clients, lists:seq(1,5)),

    %% Launch a server process for each advertisement, which will block
    %% until the advertisement should be disabled.

    %% Create a OR-set for the server list.
    {ok, Servers} = lasp:declare(riak_dt_orset),

    %% Get the current advertisement list.
    {ok, AdList} = lasp:value(Ads),

    %% For each advertisement, launch one server for tracking it's
    %% impressions and wait to disable.
    lists:foldl(fun(Ad, _Servers) ->
                ServerPid = spawn(?MODULE, server, [Ad, Ads]),
                {ok, _, _} = lasp:update(Servers, {add, ServerPid}),
                Servers
                end, Servers, AdList),

    %% Start the client simulation.

    %% Get client list.
    {ok, ClientList} = lasp:value(Clients),

    Viewer = fun(_) ->
            Pid = lists:nth(random:uniform(5), ClientList),
            Pid ! view_ad
    end,
    lists:map(Viewer, lists:seq(1,50)),

    ok.

%% @doc Server functions for the advertisement counter.  After 5 views,
%%      disable the advertisement.
%%
server(Ad, Ads) ->
    %% Blocking threshold read for 5 advertisement impressions.
    {ok, _, _, _} = lasp:read(Ad, 5),

    %% Remove the advertisement.
    {ok, _, _} = lasp:update(Ads, {remove, Ad}).

%% @doc Client process; standard recurisve looping server.
client(Id, Ads) ->
    receive
        view_ad ->
            %% Get current ad list.
            {ok, AdList} = lasp:value(Ads),

            case length(AdList) of
                0 ->
                    %% No advertisements left to display; ignore
                    %% message.
                    client(Id, Ads);
                _ ->
                    %% Select a random advertisement from the list of
                    %% active advertisements.
                    Ad = lists:nth(random:uniform(length(AdList)), AdList),

                    %% Increment it.
                    {ok, _, _} = lasp:update(Ad, increment),

                    client(Id, Ads)
            end
    end.