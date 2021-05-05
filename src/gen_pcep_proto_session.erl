-module(gen_pcep_proto_session).


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback connection_closed(pid()) -> ok.
-callback connection_error(pid(), term()) -> ok.
-callback decoding_error(pid(), map()) -> ok.
-callback decoding_warning(pid(), map()) -> ok.
-callback encoding_error(pid(), map()) -> ok.
-callback encoding_warning(pid(), map()) -> ok.
-callback pcep_message(pid(), term()) -> ok.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([new/2]).
-export([connection_closed/1]).
-export([connection_error/2]).
-export([decoding_error/2]).
-export([decoding_warning/2]).
-export([encoding_error/2]).
-export([encoding_warning/2]).
-export([pcep_message/2]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new(Mod, Pid) -> {Mod, Pid}.

connection_closed({Mod, Pid}) -> Mod:connection_closed(Pid).

connection_error({Mod, Pid}, Reason) -> Mod:connection_error(Pid, Reason).

decoding_error({Mod, Pid}, Error) -> Mod:decoding_error(Pid, Error).

decoding_warning({Mod, Pid}, Warn) -> Mod:decoding_warning(Pid, Warn).

encoding_error({Mod, Pid}, Error) -> Mod:encoding_error(Pid, Error).

encoding_warning({Mod, Pid}, Warn) -> Mod:encoding_warning(Pid, Warn).

pcep_message({Mod, Pid}, Msg) -> Mod:pcep_message(Pid, Msg).
