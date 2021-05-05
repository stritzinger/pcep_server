-module(pcep_server_session_sup).

-behaviour(supervisor).
-behaviour(gen_pcep_session_factory).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% API functions
-export([start_session/3]).

% Behaviour supervisor functions
-export([start_link/0]).
-export([init/1]).


%%% MACROS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-define(SERVER, ?MODULE).
-define(SESSION, pcep_server_session).


%%% Behaviour gen_pcep_session_factory FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_session(Proto, Id, []) ->
    case supervisor:start_child(?SERVER, [Proto, Id]) of
        {ok, Pid} ->
            {ok, gen_pcep_proto_session:new(?SESSION, Pid)};
        {ok, Pid, _Info} ->
            {ok, gen_pcep_proto_session:new(?SESSION, Pid)};
        {error, _Reason} = Error ->
            Error
    end.


%%% BEHAVIOUR SUPERVISOR FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    {ok, Handler} = application:get_env(handler),
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 0,
        period => 1
    },
    SessionSpec = #{
        id => ?SESSION,
        start => {?SESSION, start_link, [Handler]},
        restart => temporary,
        shutdown => brutal_kill
    },
    {ok, {SupFlags, [SessionSpec]}}.

