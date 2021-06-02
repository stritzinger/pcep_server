-module(pcep_server_database).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).

-export([show_routes/0]).
-export([update_route/3]).
-export([resolve/2]).
-export([register/3]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([handle_continue/2]).
-export([terminate/2]).
-export([code_change/4]).

-record(state, {
    paths = #{
        {{1, 1, 1, 1}, {6, 6, 6, 6}} => {[], [16020, 16040, 16060]},
        {{6, 6, 6, 6}, {1, 1, 1, 1}} => {[], [16040, 16020, 16010]}
    }
}).

-define(SERVER, ?MODULE).


start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

show_routes() ->
    {ok, Routes} = gen_server:call(?SERVER, routes),
    [io:format("~15s -> ~15s : ~s~n", [
                  inet:ntoa(F), inet:ntoa(T),
                  lists:join(", ", [integer_to_list(L) || L <- P])])
     || {{F, T}, {_, P}} <- maps:to_list(Routes)],
    ok.

update_route(From, To, Path) ->
    gen_server:call(?SERVER, {update, {From, To}, Path}).

resolve(From, To) ->
    gen_server:call(?SERVER, {resolve, {From, To}}).

register(From, To, Pid) ->
    gen_server:call(?SERVER, {register, {From, To}, Pid}).    

init([]) ->
    logger:info("PCEP database starting"),
    {ok, #state{}}.

handle_call(routes, _From, State) ->
    {reply, {ok, State#state.paths}, State};
handle_call({update, Key, Path}, _From, #state{paths = Paths} = State) ->
    case maps:find(Key, Paths) of
        error ->
            Paths2 = maps:put(Key, {[], Path}, Paths),
            {reply, ok, State#state{paths = Paths2}};
        {ok, {Pids, _OldPath}} ->
            Paths2 = maps:put(Key, {Pids, Path}, Paths),
            [P ! {update, Key} || P <- Pids],
            {reply, ok, State#state{paths = Paths2}}
    end;
handle_call({resolve, Key}, _From, State) ->
    case maps:find(Key, State#state.paths) of
        error -> {reply, error, State};
        {ok, {_, Path}} -> {reply, {ok, Path}, State}
    end;
handle_call({register, Key, Pid}, _From, #state{paths = Paths} = State) ->
    case maps:find(Key, Paths) of
        error ->
            erlang:link(Pid),
            Paths2 = maps:put(Key, {[Pid], []}, Paths),
            {reply, ok, State#state{paths = Paths2}};
        {ok, {Pids, Path}} ->
            case lists:member(Pid, Pids) of
                false ->
                    erlang:link(Pid),
                    Paths2 = maps:put(Key, {[Pid | Pids], Path}, Paths),
                    {reply, ok, State#state{paths = Paths2}};
                true ->
                    {reply, ok, State}
            end
    end;
handle_call(Request, From, State) ->
    logger:warning("PCEP database received unexpected call from ~w: ~w",
                   [From, Request]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Request, State) ->
    logger:warning("PCEP database protocol received unexpected cast: ~w",
                   [Request]),
    {noreply, State}.

handle_info({'DOWN', _, process, Pid, _}, #state{paths = Paths} = State) ->
    Paths2 = maps:map(fun(_, {Pids, Path}) -> {lists:delete(Pid, Pids), Path} end, Paths),
    {noreply, State#state{paths = Paths2}};
handle_info(Info, State) ->
    logger:warning("PCEP database received unexpected message: ~w",
                   [Info]),
    {noreply, State}.

handle_continue(_Continue, State) ->
    {noreply, State}.

terminate(Reason, _State) ->
    logger:warning("PCEP database terminating: ~w", [Reason]),
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.
