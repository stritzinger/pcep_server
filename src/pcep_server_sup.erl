-module(pcep_server_sup).

-behaviour(supervisor).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Behaviour supervisor functions
-export([start_link/0]).
-export([init/1]).


%%% MACROS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-define(SERVER, ?MODULE).


%%% BEHAVIOUR SUPERVISOR FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    DatabaseSpec = #{
            id => pcep_server_database,
            start => {pcep_server_database, start_link, []},
            restart => permanent
    },
    SessSupSpec = #{
            id => pcep_server_session_sup,
            start => {pcep_server_session_sup, start_link, []},
            type => supervisor,
            restart => permanent,
            shutdown => infinity
    },
    ListenerSpec = ranch:child_spec({?MODULE, pcep_server},
        ranch_tcp, #{socket_opts => [{port, 4189}]},
        pcep_server_protocol, [{pcep_server_session_sup, []}]
    ),
    {ok, {SupFlags, [DatabaseSpec, SessSupSpec, ListenerSpec]}}.

