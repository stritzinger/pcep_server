-module(gen_pcep_handler).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include("pcep_server.hrl").


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback init(Id :: binary(), Args :: term()) ->
	{ok, Opts :: init_opts(), State :: term()}.

-callback ready(Id :: binary(), PeerCaps :: [pcep_session_capability()],
                State :: term()) -> {ok, State :: term()}.

-callback synchronize_lsp(State :: term()) -> {ok, State :: term()}.

-callback request_lsp(State :: term()) -> {ok, State :: term()}.

-callback lsp_status_update(State :: term()) -> {ok, State :: term()}.

-callback lsp_delegated(State :: term()) -> {ok, State :: term()}.

-callback lsp_revoked(State :: term()) -> {ok, State :: term()}.

-callback lsp_deleted(State :: term()) -> {ok, State :: term()}.

-callback lsp_update_unacceptable(State :: term()) -> {ok, State :: term()}.

-callback invalid_operation(State :: term()) -> {ok, State :: term()}.

-callback lsp_initiated(State :: term()) -> {ok, State :: term()}.

-callback lsp_updated(State :: term()) -> {ok, State :: term()}.

-callback terminate(Reason :: term(), State :: term()) -> ok.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([init/2]).
-export([ready/3]).
-export([synchronize_lsp/1]).
-export([request_lsp/1]).
-export([lsp_status_update/1]).
-export([lsp_delegated/1]).
-export([lsp_revoked/1]).
-export([lsp_deleted/1]).
-export([lsp_update_unacceptable/1]).
-export([invalid_operation/1]).
-export([lsp_initiated/1]).
-export([lsp_updated/1]).
-export([terminate/2]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Id, {Mod, Args}) ->
	case Mod:init(Id, Args) of
		{ok, Opts, State} -> {ok, Opts, {Mod, State}}
	end.

ready(Id, Caps, {Mod, State}) ->
    case Mod:ready(Id, Caps, State) of
        {ok, NewState} -> {ok, {Mod, NewState}}
    end.

synchronize_lsp({Mod, State}) ->
	case Mod:synchronize_lsp(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

request_lsp({Mod, State}) ->
	case Mod:request_lsp(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_status_update({Mod, State}) ->
	case Mod:lsp_status_update(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_delegated({Mod, State}) ->
	case Mod:lsp_delegated(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_revoked({Mod, State}) ->
	case Mod:lsp_revoked(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_deleted({Mod, State}) ->
	case Mod:lsp_deleted(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_update_unacceptable({Mod, State}) ->
	case Mod:lsp_update_unacceptable(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

invalid_operation({Mod, State}) ->
	case Mod:invalid_operation(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_initiated({Mod, State}) ->
	case Mod:lsp_initiated(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

lsp_updated({Mod, State}) ->
	case Mod:lsp_updated(State) of
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

terminate(Reason, {Mod, State}) ->
    Mod:terminate(Reason, State).
