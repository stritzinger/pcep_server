-module(gen_pcep_handler).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include("pcep_server.hrl").


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback init(Args :: term()) ->
	{ok, Opts :: init_opts(), State :: term()}.

-callback opened(Id :: inet:ip_address(),
                 PeerCaps :: [pcep_session_capability()],
                 Session :: pid(), State :: term()) ->
    {ok, State :: term()}.

-callback flow_added(Flow :: te_flow(), State :: term()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

-callback ready(State :: term()) ->
    {ok, State :: term()}.

-callback request_route(te_route_request(), State :: term())
    -> {ok, te_route(), State :: term()}
     | {error, computation_error(), [te_flow_constraint()]}
     | {error, computation_error()}.

-callback flow_delegated(te_flow(), State :: term())
    -> {ok, State :: term()}
     | {error, Reason :: term()}.

-callback flow_status_changed(FlowId :: flow_id(), NewStatus :: te_opstatus(),
                              State :: term()) -> {ok, State :: term()}.

-callback terminate(Reason :: term(), State :: term()) -> ok.


%%% TYPES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type computation_error() :: path_not_found
                           | pce_chain_broken
                           | pce_unavailable
                           | unknown_destination
                           | unknown_source.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([init/1]).
-export([opened/4]).
-export([flow_added/2]).
-export([ready/1]).
-export([request_route/2]).
-export([flow_delegated/2]).
-export([flow_status_changed/3]).
-export([terminate/2]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({Mod, Args}) ->
	case Mod:init(Args) of
		{ok, Opts, State} -> {ok, Opts, {Mod, State}}
	end.

opened(Id, Caps, Sess, {Mod, State}) ->
    case Mod:opened(Id, Caps, Sess, State) of
        {ok, NewState} -> {ok, {Mod, NewState}}
    end.

flow_added(Flow, {Mod, State}) ->
	case Mod:flow_added(Flow, State) of
        {error, _Reason} = Error -> Error;
		{ok, NewState} -> {ok, {Mod, NewState}}
	end.

ready({Mod, State}) ->
    case Mod:ready(State) of
        {ok, NewState} -> {ok, {Mod, NewState}}
    end.

request_route(RouteReq, {Mod, State}) ->
	case Mod:request_route(RouteReq, State) of
		{ok, Route, NewState} -> {ok, Route, {Mod, NewState}};
        {error, _Reason, _Constraints} = Error -> Error;
        {error, _Reason} = Error -> Error
	end.

flow_delegated(Flow, {Mod, State}) ->
    case Mod:flow_delegated(Flow, State) of
        {ok, NewState} -> {ok, {Mod, NewState}};
        {error, _Reason} = Error -> Error
    end.

flow_status_changed(FlowId, NewStatus, {Mod, State}) ->
    {ok, NewState} = Mod:flow_status_changed(FlowId, NewStatus, State),
    {ok, {Mod, NewState}}.

terminate(Reason, {Mod, State}) ->
    Mod:terminate(Reason, State).
