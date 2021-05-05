-module(gen_pcep_session_factory).


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback start_session(Proto :: term(), Id :: binary(), Args :: list()) ->
	{ok, Sess :: term()} | {error, Reason :: term()}.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([start_session/3]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_session({Mod, Args}, Proto, Id) -> Mod:start_session(Proto, Id, Args).
