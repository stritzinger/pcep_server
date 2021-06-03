-module(gen_pcep_session_factory).


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback start_session(Proto :: term(),
        Peer :: {inet:ip_address(), inet:port_number()}, Args :: list()) ->
	{ok, Sess :: term()} | {error, Reason :: term()}.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([start_session/3]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_session({Mod, Args}, Proto, Peer) -> Mod:start_session(Proto, Peer, Args).
