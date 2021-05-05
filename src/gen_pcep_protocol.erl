-module(gen_pcep_protocol).


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback send(pid(), term()) -> ok.
-callback close(pid()) -> ok.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([new/2]).
-export([link/1]).
-export([send/2]).
-export([close/1]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new(Mod, Pid) -> {Mod, Pid}.

link({_Mod, Pid}) -> erlang:link(Pid).

send({Mod, Pid}, Msg) -> Mod:send(Pid, Msg).

close({Mod, Pid}) -> Mod:close(Pid).
