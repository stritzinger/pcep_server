-module(pcep_server_protocol).

-behaviour(gen_pcep_protocol).
-behaviour(ranch_protocol).
-behaviour(gen_server).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Behaviour gen_pcep_protocol functions
-export([send/2]).
-export([close/1]).

% Behaviour ranch_protocol functions
-export([start_link/3]).

% Behaviour gen_server functions
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([handle_continue/2]).
-export([terminate/2]).
-export([code_change/4]).


%%% RECORDS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {sock, tran, buff, id, sess}).


%%% MACROS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-define(ACTIVE_COUNT, 100).


%%% Behaviour gen_pcep_protocol FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

send(Ref, Msg) ->
    gen_server:cast(Ref, {send, Msg}).

close(Ref) ->
    gen_server:cast(Ref, close).    


%%% Behaviour ranch_protocol FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Ref, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Transport, Opts}])}.


%%% Behaviour gen_statem FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({Ref, Transport, [Factory]}) ->
    {ok, Socket} = ranch:handshake(Ref),
    Proto = gen_pcep_protocol:new(?MODULE, self()),
    {ok, {Addr, _Port}} = Transport:peername(Socket),
    Id = list_to_binary(inet:ntoa(Addr)),
    {ok, Sess} = gen_pcep_session_factory:start_session(Factory, Proto, Id),
    ok = Transport:setopts(Socket, [{active, ?ACTIVE_COUNT}]),
    State = #state{sock = Socket, tran = Transport, buff = <<>>,
                   id = Id, sess = Sess},
    gen_server:enter_loop(?MODULE, [], State).

handle_call(Request, From, #state{id = Id} = State) ->
    logger:warning("[~s] PCEP server protocol received unexpected call from ~w: ~w",
                   [Id, From, Request]),
    {reply, {error, unexpected_call}, State}.

handle_cast({send, Msg}, #state{sock = S, tran = T,
                                sess = Sess, id = Id} = State) ->
    logger:debug("[~s] >>>>> ~w", [Id, Msg]),
    case pcep_codec:encode(Msg) of
        {error, _Reason, Error, Warnings} ->
            gen_pcep_proto_session:encoding_error(Sess, Error),
            [gen_pcep_proto_session:encoding_warning(Sess, W) || W <- Warnings],
            {noreply, State};
        {ok, Data, Warnings} ->
            [gen_pcep_proto_session:encoding_warning(Sess, W) || W <- Warnings],
            T:send(S, Data),
            {noreply, State}
    end;
handle_cast(close, #state{sock = S, tran = T, id = Id} = State) ->
    logger:debug("[~s] Closing PCEP protocol transport", [Id]),
    T:close(S),
    {noreply, State};
handle_cast(Request, #state{id = Id} = State) ->
    logger:warning("[~s] PCEP server protocol received unexpected cast: ~w",
                   [Id, Request]),
    {noreply, State}.

handle_info({tcp, Sock, Data},
            #state{sock = Sock} = State) ->
    {noreply, decode(State, Data)};
handle_info({tcp_passive, Sock},
            #state{sock = Sock, tran = Tran} = State) ->
    ok = Tran:setopts(Sock, [{active, ?ACTIVE_COUNT}]),
    {noreply, State};
handle_info({tcp_closed, Sock},
            #state{sock = Sock, sess = Sess} = State) ->
    gen_pcep_proto_session:connection_closed(Sess),
    {stop, normal, State};
handle_info({tcp_error, Sock, Reason},
            #state{sock = Sock, sess = Sess} = State) ->
    gen_pcep_proto_session:connection_error(Sess, Reason),
    {stop, Reason, State};
handle_info(Info, #state{id = Id} = State) ->
    logger:warning("[~s] PCEP server protocol received unexpected message: ~w",
                   [Id, Info]),
    {noreply, State}.


handle_continue(_Continue, State) ->
    {noreply, State}.

terminate(normal, _State) ->
    ok;
terminate(Reason, _State) ->
    logger:warning("PCEP server protocol terminating: ~w", [Reason]),
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

decode(#state{buff = Buff} = State, Data) ->
    decode_loop(State#state{buff = <<Buff/binary, Data/binary>>}).

decode_loop(#state{buff = Buff, sess = Sess, id = Id} = State) ->   
    case pcep_codec:decode(Buff) of
        {more, _Length} ->
            %TODO: if the buffer grows too much, close the connection
            State;
        {error, _Reason, Error, Warnings, RemData} ->
            gen_pcep_proto_session:decoding_error(Sess, Error),
            [gen_pcep_proto_session:decoding_warning(Sess, W) || W <- Warnings],
            decode_loop(State#state{buff = RemData});
        {ok, Msg, Warnings, RemData} ->
            logger:debug("[~s] <<<<< ~w", [Id, Msg]),
            [gen_pcep_proto_session:decoding_warning(Sess, W) || W <- Warnings],
            gen_pcep_proto_session:pcep_message(Sess, Msg),
            decode_loop(State#state{buff = RemData})
    end.


