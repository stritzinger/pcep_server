-module(pcep_server_app).

-behaviour(application).


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Behaviour application functions
-export([start/2, stop/1]).


%%% BEHAVIOUR application FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(_StartType, _StartArgs) ->
    pcep_server_sup:start_link().

stop(_State) ->
    ok.
