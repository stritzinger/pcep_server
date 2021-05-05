-module(gen_pcep_server_session).


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback synchronization_error(pid()) -> ok.
-callback resource_exceeded(pid()) -> ok.
-callback computation_succeed(pid()) -> ok.
-callback computation_failed(pid()) -> ok.
-callback computation_canceled(pid()) -> ok.
-callback initiate_lsp(pid()) -> ok.
-callback update_lsp(pid()) -> ok.
-callback reject_lsp(pid()) -> ok.
-callback accept_lsp(pid()) -> ok.
-callback return_lsp(pid()) -> ok.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([new/2]).
-export([synchronization_error/1]).
-export([resource_exceeded/1]).
-export([computation_succeed/1]).
-export([computation_failed/1]).
-export([computation_canceled/1]).
-export([initiate_lsp/1]).
-export([update_lsp/1]).
-export([reject_lsp/1]).
-export([accept_lsp/1]).
-export([return_lsp/1]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new(Mod, Pid) -> {Mod, Pid}.

synchronization_error({Mod, Pid}) -> Mod:synchronization_error(Pid).

resource_exceeded({Mod, Pid}) -> Mod:resource_exceeded(Pid).

computation_succeed({Mod, Pid}) -> Mod:computation_succeed(Pid).

computation_failed({Mod, Pid}) -> Mod:computation_failed(Pid).

computation_canceled({Mod, Pid}) -> Mod:computation_canceled(Pid).

initiate_lsp({Mod, Pid}) -> Mod:initiate_lsp(Pid).

update_lsp({Mod, Pid}) -> Mod:update_lsp(Pid).

reject_lsp({Mod, Pid}) -> Mod:reject_lsp(Pid).

accept_lsp({Mod, Pid}) -> Mod:accept_lsp(Pid).

return_lsp({Mod, Pid}) -> Mod:return_lsp(Pid).
