-module(pcep_server_session).

%TODO: Implement OPEN negociation; When a negociable error is recevied during
%      handshake, and it contains an open object, we should send a second open
%      message and wait for one. If the second time negotiation fails we close
%      the connection.

-behaviour(gen_statem).
-behaviour(gen_pcep_proto_session).
-behaviour(gen_pcep_server_session).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").
-include_lib("pcep_codec/include/pcep_codec.hrl").


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% API functions
-export([start_link/3]).

% Behaviour gen_pcep_proto_session functions
-export([connection_closed/1]).
-export([connection_error/2]).
-export([decoding_error/2]).
-export([decoding_warning/2]).
-export([encoding_error/2]).
-export([encoding_warning/2]).
-export([pcep_message/2]).

% Behaviour gen_pcep_server_session functions
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

% Behaviour gen_statem functions
-export([init/1]).
-export([callback_mode/0]).
-export([handle_event/4]).
-export([terminate/3]).
-export([code_change/4]).


%%% Records %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(data, {
    id,
    proto,
    handler,
    sid,
    openwait_timeout,
    keepwait_timeout,
    sync_timeout,
    keepalive_timeout,
    deadtimer_timeout,
    required_caps = [],
    peer_caps = [],
    peer_msd,
    plspid,
    srpid,
    lsp
}).


%%% MACROS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-define(DEFAULT_OPENWAIT_TIMEOUT, 60000).
-define(DEFAULT_KEEPWAIT_TIMEOUT, 60000).
-define(DEFAULT_SYNC_TIMEOUT, 120000).
-define(DEFAULT_KEEPALIVE_TIMEOUT, 30000).
-define(MIN_KEEPALIVE_TIMEOUT, 5000).
-define(MAX_KEEPALIVE_TIMEOUT, 120000).
-define(DEFAULT_DEADTIMER_TIMEOUT, (?DEFAULT_KEEPALIVE_TIMEOUT * 4)).
-define(MIN_DEADTIMER_TIMEOUT, (?MIN_KEEPALIVE_TIMEOUT * 4)).
-define(MAX_DEADTIMER_TIMEOUT, (?MAX_KEEPALIVE_TIMEOUT * 4)).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Handler, Proto, Id) ->
    gen_statem:start_link(?MODULE, [Handler, Proto, Id], []).


%%% Behaviour gen_pcep_proto_session FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connection_closed(Pid) ->
    gen_statem:cast(Pid, connection_closed).

connection_error(Pid, Reason) ->
    gen_statem:cast(Pid, {error, connection, Reason}).

decoding_error(Pid, Error) ->
    gen_statem:cast(Pid, {error, decoding, Error}).

decoding_warning(Pid, Warn) ->
    gen_statem:cast(Pid, {warn, decoding, Warn}).

encoding_error(Pid, Error) ->
    gen_statem:cast(Pid, {error, encoding, Error}).

encoding_warning(Pid, Warn) ->
    gen_statem:cast(Pid, {error, encoding, Warn}).

pcep_message(Pid, Msg) ->
    gen_statem:cast(Pid, {pcep, Msg}).


%%% Behaviour gen_pcep_server_session FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

synchronization_error(Pid) ->
    gen_statem:cast(Pid, synchronization_error).

resource_exceeded(Pid) ->
    gen_statem:cast(Pid, resource_exceeded).

computation_succeed(Pid) ->
    gen_statem:cast(Pid, computation_succeed).

computation_failed(Pid) ->
    gen_statem:cast(Pid, computation_failed).

computation_canceled(Pid) ->
    gen_statem:cast(Pid, computation_canceled).

initiate_lsp(Pid) ->
    gen_statem:cast(Pid, initiate_lsp).

update_lsp(Pid) ->
    gen_statem:cast(Pid, update_lsp).

reject_lsp(Pid) ->
    gen_statem:cast(Pid, reject_lsp).

accept_lsp(Pid) ->
    gen_statem:cast(Pid, accept_lsp).

return_lsp(Pid) ->
    gen_statem:cast(Pid, return_lsp).


%%% Behaviour gen_statem FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([Handler, Proto, Id]) ->
    gen_pcep_protocol:link(Proto),
    {ok, HandlerOpts, NewHandler} = gen_pcep_handler:init(Id, Handler),
    OpenWaitTimeout = maps:get(openwait_timeout, HandlerOpts,
                               ?DEFAULT_OPENWAIT_TIMEOUT),
    KeepWaitTimeout = maps:get(keepwait_timeout, HandlerOpts,
                               ?DEFAULT_OPENWAIT_TIMEOUT),
    SyncTimeout = maps:get(sync_timeout, HandlerOpts,
                           ?DEFAULT_SYNC_TIMEOUT),
    KeepaliveTimeout = get_bounded(
        maps:get(keepalive_timeout, HandlerOpts, undefined),
        ?DEFAULT_KEEPALIVE_TIMEOUT, ?MIN_KEEPALIVE_TIMEOUT,
        ?MAX_KEEPALIVE_TIMEOUT),
    DeadtimerTimeout = get_bounded(
        maps:get(deadtimer_timeout, HandlerOpts, undefined),
        ?DEFAULT_DEADTIMER_TIMEOUT, ?MIN_DEADTIMER_TIMEOUT,
        ?MAX_DEADTIMER_TIMEOUT),
    RequiredCaps = maps:get(required_capabilities, HandlerOpts,
                            [stateful, lsp_update]),
    Data = #data{
        id = Id,
        proto = Proto,
        handler = NewHandler,
        openwait_timeout = OpenWaitTimeout,
        keepwait_timeout = KeepWaitTimeout,
        sync_timeout = SyncTimeout,
        keepalive_timeout = KeepaliveTimeout,
        deadtimer_timeout = DeadtimerTimeout,
        required_caps = RequiredCaps
    },
    log_info(Data, "Starting PCEP session"),
    {ok, openwait, Data}.

callback_mode() -> [handle_event_function, state_enter].

%-- OPENWAIT STATE -------------------------------------------------------------
handle_event(enter, _, openwait,
             #data{proto = Proto, openwait_timeout = OpenWaitTimeout} = Data) ->
    % log_debug(Data, "Sending open message and waiting for peer's"),
    Msg = #pcep_msg_open{open = handshake_start(Data)},
    gen_pcep_protocol:send(Proto, Msg),
    {keep_state, Data, [{state_timeout, OpenWaitTimeout, openwait_timeout}]};
handle_event(state_timeout, openwait_timeout, openwait, Data) ->
    log_info(Data, "Handshake timed out waiting for open message, closing PCEP session"),
    stop_session(Data, handshake_error, session_failure, openwait_timed_out);
handle_event(cast, {pcep, #pcep_msg_open{open = Open}}, openwait, Data) ->
    case handshake_negotiate(Data, Open) of
        {close, ErrT, ErrV, Data2} ->
            stop_session(Data2, handshake_error, ErrT, ErrV);
        {done, Data2} ->
            {next_state, keepwait, Data2}
    end;
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             openwait, Data) ->
    %TODO: Add support for negociation
    case handshake_errors(Data, Errors) of
        {close, Data2} ->
            stop_session(Data2, handshake_error)
    end;
handle_event(cast, {pcep, Msg}, openwait, Data) ->
    log_error(Data, "Unexpected PCEP message ~w received before OPEN",
              [element(1, Msg)]),
    stop_session(Data, handshake_error, session_failure, invalid_open_message);
%-- KEEPWAIT STATE -------------------------------------------------------------
handle_event(enter, _, keepwait,
             #data{keepwait_timeout = KeepWaitTimeout} = Data) ->
    % log_debug(Data, "Sending first keep-alive message and waiting for peer's"),
    send_keepalive(Data),
    {keep_state, Data, [
        {state_timeout, KeepWaitTimeout, keepwait_timeout}
    | update_keepalive(Data)]};
handle_event(cast, {pcep, #pcep_msg_keepalive{}}, keepwait, Data) ->
    {next_state, synchronize, Data, update_deadtimer(Data)};
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             keepwait, Data) ->
    %TODO: Add support for negociation
    case handshake_errors(Data, Errors) of
        {close, Data2} ->
            stop_session(Data2, handshake_error)
    end;
handle_event(state_timeout, keepwait_timeout, keepwait, Data) ->
    log_error(Data, "Handshake timed out waiting for keep-alive message, closing PCEP session"),
    stop_session(Data, handshake_error, session_failure,
                 keepalivewait_timed_out);
handle_event(cast, {pcep, Msg}, keepwait, Data) ->
    log_error(Data, "Unexpected PCEP message ~w received during handshake",
              [element(1, Msg)]),
    % The expected error value in this case is not clear.
    stop_session(Data, handshake_error, session_failure, session_failure);
%-- SYNCHRONIZE STATE ----------------------------------------------------------
handle_event(enter, _, synchronize, #data{sync_timeout = Timeout} = Data) ->
    {keep_state, Data, [{state_timeout, Timeout, sync_timeout}]};
handle_event(cast, {pcep, #pcep_msg_report{report_list = Reports}},
             synchronize, Data) ->    
    case synchronize_reports(Data, Reports) of
        {done, NewData} ->
            {next_state, ready, NewData, update_deadtimer(Data)};
        {continue, NewData} ->
            {keep_state, NewData, update_deadtimer(Data)}
    end;
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             synchronize, Data) ->
    case synchronize_errors(Data, Errors) of
        {close, Data2} ->
            stop_session(Data2, sync_error)
    end;
handle_event(cast, {pcep, Msg}, synchronize, Data) -> 
    log_error(Data, "Unexpected PCEP message during sunchronization: ~w",
              [Msg]),
    % The expected error value in this case is not clear.
    stop_session(Data, sync_error, lsp_state_sync_error, lsp_state_sync_error);
handle_event(state_timeout, sync_timeout, synchronize, Data) ->
    log_error(Data, "Synchronization timed out, closing PCEP session"),
    % The expected error value in this case is not clear.
    stop_session(Data, sync_error, lsp_state_sync_error, lsp_state_sync_error);
%-- READY STATE ----------------------------------------------------------------
handle_event(enter, _, ready, Data) ->
    {ok, NewData} = handler_ready(Data),
    {keep_state, NewData};
handle_event(cast, {pcep, #pcep_msg_report{report_list = Reports}},
             ready, Data) ->    
    %TODO: return error if statefull capabiliti is not supported : https://tools.ietf.org/html/rfc8231#section-5.4
    case handle_reports(Data, Reports) of
        {noreply, NewData} ->
            {keep_state, NewData, update_deadtimer(Data)}
    end;
handle_event(cast, {pcep, #pcep_msg_compreq{request_list = Requests}},
             ready, Data) ->    
    %TODO: check the lsp is not already delegated
    case handle_requests(Data, Requests) of
        {noreply, NewData} ->
            {keep_state, NewData, update_deadtimer(Data)}
    end;
handle_event(cast, {pcep, #pcep_msg_notif{notif_list = Notifications}},
             ready, Data) ->    
    case handle_notifications(Data, Notifications) of
        {noreply, NewData} ->
            {keep_state, NewData, update_deadtimer(Data)}
    end;
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             ready, Data) ->    
    case handle_errors(Data, Errors) of
        {noreply, NewData} ->
            {keep_state, NewData, update_deadtimer(Data)}
    end;
handle_event(info, {update, Key}, ready, Data) ->
    {keep_state, update_route(Data, Key)};
%-- ANY STATE ------------------------------------------------------------------
handle_event(cast, {pcep, #pcep_msg_close{close = Close}}, _State, Data) ->
    Reason = Close#pcep_obj_close.reason,
    log_info(Data, "PCEP Session closed by peer: ~w", [Reason]),
    stop_session(Data, closed);
handle_event(cast, {pcep, #pcep_msg_keepalive{}}, _State, Data) ->
    {keep_state, Data, update_deadtimer(Data)};
handle_event(cast, {pcep, Msg}, _State, Data) -> 
    log_warn(Data, "Session received unexpected PCEP message: ~w", [Msg]),
    %TODO: Limit the rate of unknown messages
    {keep_state_and_data, update_deadtimer(Data)};
handle_event({timeout, keepalive}, keepalive, _State, Data) ->
    send_keepalive(Data),
    {keep_state, Data, update_keepalive(Data)};
handle_event({timeout, deadtimer}, deadtimer, _State, Data) ->
    log_error(Data, "No activity detected, closing PCEP session"),
    stop_session(Data, activity_timeout);
handle_event(cast, connection_closed, _State, Data) ->
    log_info(Data, "Connection closed by peer ????"),
    stop_session(Data, closed);
handle_event(cast, {warn, _, _Warn}, _State, Data) ->
    % log_warn(Data, Warn),
    {keep_state, Data};
handle_event(cast, {error, connection, Reason}, _State, Data) ->
    log_info(Data, "Connection error ~w", [Reason]),
    stop_session(Data, closed);
handle_event(cast, {error, decoding, Error}, _State, Data) ->
    log_error(Data, Error),
    %TODO: handle maximum number of unknown messages : https://tools.ietf.org/html/rfc5440#section-8.1
    %TODO: handle maximum number of unknown objects : https://tools.ietf.org/html/rfc5440#section-8.1
    stop_session(Data, {decoding_error, maps:get(type, Error, unknown)});
handle_event(cast, {error, encoding, Error}, _State, Data) ->
    log_error(Data, Error),
    stop_session(Data, {encoding_error, maps:get(type, Error, unknown)});
handle_event(EventType, EventContent, State, Data) ->
    log_debug(Data, "PCEP session received unexpected ~w event in state ~w: ~w",
              [EventType, State, EventContent]),
    {keep_state, Data}.

terminate(Reason, _State, Data) ->
    handler_terminate(Data, Reason),
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%-- Logging Utility Functions --------------------------------------------------

log_debug(#data{id = Id}, Fmt) when is_list(Fmt)->
    logger:debug("[~s] " ++ Fmt, [Id]).

log_debug(#data{id = Id}, Fmt, Args) ->
    logger:debug("[~s] " ++ Fmt, [Id | Args]).

log_info(#data{id = Id}, Fmt) ->
    logger:info("[~s] " ++ Fmt, [Id]).

log_info(#data{id = Id}, Fmt, Args) ->
    logger:info("[~s] " ++ Fmt, [Id | Args]).

% log_warn(#data{id = Id}, Map) when is_map(Map) ->
%     logger:warning(Map#{peer => Id}).

log_warn(#data{id = Id}, Fmt, Args) ->
    logger:warning("[~s] " ++ Fmt, [Id | Args]).

log_error(#data{id = Id}, Map) when is_map(Map) ->
    logger:error(Map#{peer => Id});
log_error(#data{id = Id}, Fmt) ->
    logger:info("[~s] " ++ Fmt, [Id]).

log_error(#data{id = Id}, Fmt, Args) ->
    logger:error("[~s] " ++ Fmt, [Id | Args]).


%-- Utility Functions ----------------------------------------------------------

get_bounded(undefined, Def, _Min, _Max) -> Def;
get_bounded(infinity, _Def, _Min, Max) -> Max;
get_bounded(0, _Def, _Min, Max) -> Max;
get_bounded(Val, _Def, Min, _Max) when Val < Min -> Min;
get_bounded(Val, _Def, _Min, Max) when is_integer(Max), Val > Max -> Max;
get_bounded(Val, _Def, _Min, _Max) -> Val.

get_tlv(_Name, []) -> undefined;
get_tlv(Name, [Rec | _Rest]) when element(1, Rec) =:= Name -> Rec;
get_tlv(Name, [_ | Rest]) -> get_tlv(Name, Rest).

timeout_to_pcep(infinity) -> 0;
timeout_to_pcep(MiliSec) -> MiliSec div 1000.

pcep_to_timeout(0) -> infinity;
pcep_to_timeout(Sec) -> Sec * 1000.

stop_session(#data{proto = Proto} = Data, Reason) ->
    NewData = handler_terminate(Data, Reason),
    gen_pcep_protocol:close(Proto),
    {stop, normal, NewData}.

stop_session(#data{proto = Proto} = Data, Reason, ErrC, ErrV) ->
    NewData = handler_terminate(Data, Reason),
    Msg = make_pcep_error(ErrC, ErrV),
    gen_pcep_protocol:send(Proto, Msg),
    gen_pcep_protocol:close(Proto),
    {stop, normal, NewData}.


%-- Handshake Functions --------------------------------------------------------

handshake_start(#data{keepalive_timeout = KeepaliveTimeout,
                      deadtimer_timeout = DeadtimerTimeout}) ->
    #pcep_obj_open{
        keepalive = timeout_to_pcep(KeepaliveTimeout),
        dead_timer = timeout_to_pcep(DeadtimerTimeout),
        tlvs = [
               #pcep_tlv_stateful_pce_cap{flag_u = true, flag_i = true},
               #pcep_tlv_sr_pce_cap{msd = 10}, % Deprecated TLV
               #pcep_tlv_path_setup_type_cap{psts = [srte], subtlvs = [
                    #pcep_subtlv_path_setup_type_cap_sr{msd = 10}
               ]}
          ]
     }.

check_stateful(#data{required_caps = ReqCaps} = Data, Open, Status) ->
    TLVs = Open#pcep_obj_open.tlvs,
    case {lists:member(stateful, ReqCaps),
          lists:member(lsp_update, ReqCaps),
          lists:member(initiated_lsp, ReqCaps),
          get_tlv(pcep_tlv_stateful_pce_cap, TLVs)} of
        {S, U, I, undefined} when S =:= false; U =:= false; I =:= false ->
            log_error(Data, "PCC doesn't support required stateful capabilities"),
            {unnegotiable, Data};
        {_, Us, _, #pcep_tlv_stateful_pce_cap{flag_u = Uc}}
          when Us =:= true, Uc =:= false ->
            log_error(Data, "PCC doesn't support required LSP update capability"),
            {unnegotiable, Data};
        {_, _, Is, #pcep_tlv_stateful_pce_cap{flag_i = Ic}}
          when Is =:= true, Ic =:= false ->
            log_error(Data, "PCC doesn't support required PCE Initiated LSP capability"),
            {unnegotiable, Data};
        {_, _, _, #pcep_tlv_stateful_pce_cap{flag_u = U, flag_i = I}} ->
            Caps = Data#data.peer_caps,
            Caps2 = if I -> [initiated_lsp | Caps]; true -> Caps end,
            Caps3 = if U -> [lsp_update | Caps2]; true -> Caps2 end,
            {Status, Open, Data#data{peer_caps = [stateful | Caps3]}};
        {_, _, _, undefined} ->
            {Status, Open, Data}
    end.

check_srte(#data{required_caps = ReqCaps} = Data, Open, Status) ->
    TLVs = Open#pcep_obj_open.tlvs,
    NeedsNAIToSID = lists:member(srte_nai_to_sid, ReqCaps),
    NeedsUnlimitedMSD = lists:member(srte_unlimited_msd, ReqCaps),
    case get_tlv(pcep_tlv_path_setup_type_cap, TLVs) of
        undefined ->
            %DEPRECATED: Check for deprecated TLV still used by Cisco
            case {NeedsNAIToSID, NeedsUnlimitedMSD,
                  get_tlv(pcep_tlv_sr_pce_cap, TLVs)} of
                {_, _, undefined} ->
                    log_error(Data, "PCC doesn't support SRTE"),
                    {unnegotiable, Data};
                {true, _, #pcep_tlv_sr_pce_cap{}} ->
                    log_error(Data, "PCC doesn't support required SRTE NAI to SID conversion capability"),
                    {unnegotiable, Data};
                {_, true, #pcep_tlv_sr_pce_cap{}} ->
                    log_error(Data, "PCC doesn't support required SRTE unlimited MSD capability"),
                    {unnegotiable, Data};
                {_, _, #pcep_tlv_sr_pce_cap{msd = 0}} ->
                    {error, invalid_object, msd_must_be_nonzero, Data};
                {_, _, #pcep_tlv_sr_pce_cap{msd = MSD}} ->
                    {Status, Open, Data#data{peer_msd = MSD}}
            end;
        #pcep_tlv_path_setup_type_cap{psts = PSTs, subtlvs = SubTLVs} ->
            case lists:member(srte, PSTs) of
                false -> 
                    log_error(Data, "PCC doesn't support SRTE"),
                    {unnegotiable, Data};
                true ->
                    case {NeedsNAIToSID, NeedsUnlimitedMSD,
                          get_tlv(pcep_subtlv_path_setup_type_cap_sr,
                                  SubTLVs)} of
                        {_, _, undefined} ->
                            {error, invalid_object, sr_cap_tlv_missing, Data};
                        {true, _, #pcep_subtlv_path_setup_type_cap_sr{
                                        flag_n = false}} ->
                            log_error(Data, "PCC doesn't support required SRTE NAI to SID conversion capability"),
                            {unnegotiable, Data};
                        {_, true, #pcep_subtlv_path_setup_type_cap_sr{
                                        flag_x = false}} ->
                            log_error(Data, "PCC doesn't support required SRTE unlimited MSD capability"),
                            {unnegotiable, Data};
                        {_, _, #pcep_subtlv_path_setup_type_cap_sr{
                                        flag_x = false, msd = 0}} ->
                            {error, invalid_object, msd_must_be_nonzero, Data};
                        {_, _, #pcep_subtlv_path_setup_type_cap_sr{
                                        flag_n = N, flag_x = X, msd = MSD}} ->
                            Caps = Data#data.peer_caps,
                            Caps2 = case N of
                                true -> [srte_nai_to_sid | Caps];
                                false -> Caps
                            end,
                            Data2 = case X of
                                true ->
                                    Data#data{
                                        peer_caps = [srte_unlimited_msd | Caps2],
                                        peer_msd = infinity
                                    };
                                false ->
                                    Data#data{
                                        peer_caps = Caps2,
                                        peer_msd = MSD
                                    }
                            end,
                            {Status, Open, Data2}
                    end
            end
    end.

handshake_apply(Data, Open, Checks) ->
    handshake_apply(Data, Open, agreed, Checks).

handshake_apply(Data, _Open, agreed, []) ->
    {done, Data};
% handshake_apply(Data, Open, negotiable, []) ->
%     {retry, session_failure, unacceptable_open_msg_neg, Open, Data};
handshake_apply(Data, Open, Status, [Check | Rest]) ->
    case Check(Data, Open, Status) of
        {error, Type, Value, NewData} ->
            {close, Type, Value, NewData};
        {unnegotiable, NewData} ->
            {close, session_failure, unacceptable_open_msg_no_neg, NewData};
        {Status, NewOpen, NewData} ->
            handshake_apply(NewData, NewOpen, Status, Rest)
    end.

handshake_negotiate(#data{id = Id} = Data, Open) ->
    case handshake_apply(Data, Open,
                         [fun check_stateful/3, fun check_srte/3]) of
        {done, Data2} ->
            Sid = Open#pcep_obj_open.sid,
            SidBin = integer_to_binary(Sid),
            Id2 = <<Id/binary,$:,SidBin/binary>>,
            Data3 = Data2#data{
                sid = Sid,
                id = Id2,
                keepalive_timeout = get_bounded(
                    pcep_to_timeout(Open#pcep_obj_open.keepalive),
                    Data#data.keepalive_timeout, ?MIN_KEEPALIVE_TIMEOUT,
                    ?MAX_KEEPALIVE_TIMEOUT),
                deadtimer_timeout = get_bounded(
                    pcep_to_timeout(Open#pcep_obj_open.dead_timer),
                    Data#data.deadtimer_timeout, ?MIN_DEADTIMER_TIMEOUT,
                    ?MAX_DEADTIMER_TIMEOUT)
            },
            {done, Data3};
        Other ->
            Other
    end.

handshake_errors(Data, []) ->
    {close, Data};
handshake_errors(Data, [Error | Rest]) ->
    log_error(Data, "Handshake error: ~w", [Error]),
    handshake_errors(Data, Rest).


%-- Synchronization Functions --------------------------------------------------

synchronize_reports(Data, []) ->
    {continue, Data};
synchronize_reports(Data, [#pcep_report{
        lsp = #pcep_obj_lsp{flag_s = false, plsp_id = 0}}]) ->
    {done, Data};
synchronize_reports(Data, [#pcep_report{
        lsp = #pcep_obj_lsp{flag_s = true}} = _Report | Rest]) ->
    %TODO: call handler
    % log_debug(Data, "Received synchronization report"),
    synchronize_reports(Data, Rest).

synchronize_errors(Data, []) ->
    {close, Data};
synchronize_errors(Data, [Error | Rest]) ->
    log_error(Data, "Synchronization error: ~w", [Error]),
    synchronize_errors(Data, Rest).


%-- Keepalive Handling Functions -----------------------------------------------

send_keepalive(#data{keepalive_timeout = 0}) ->
    ok;
send_keepalive(#data{proto = Proto}) ->
    gen_pcep_protocol:send(Proto, #pcep_msg_keepalive{}).

update_keepalive(#data{keepalive_timeout = 0}) ->
    [];
update_keepalive(#data{keepalive_timeout = Keepalive}) ->
    [{{timeout, keepalive}, Keepalive, keepalive}].

update_deadtimer(#data{deadtimer_timeout = 0}) ->
    [];
update_deadtimer(#data{deadtimer_timeout = Deadtimer}) ->
    [{{timeout, deadtimer}, Deadtimer, deadtimer}].


%-- PCEP Structure Helper Functions --------------------------------------------

make_pcep_error(ErrT, ErrV) ->
    #pcep_msg_error{
        error_list = [
            #pcep_error{errors = [#pcep_obj_error{type = ErrT, value = ErrV}]}
        ]
    }.


%-- PCEP Message Handlers ------------------------------------------------------

update_route(#data{proto = Proto, srpid = SRPID, lsp = LSP} = Data, {From, To}) ->
    case pcep_server_database:resolve(From, To) of
        error -> 
            log_warn(Data, "Couldn't resolve updated route from ~s to ~s",
                     [inet:ntoa(From), inet:ntoa(To)]),
            Data;
        {ok, Labels} ->
            log_info(Data, "Updating route from ~s to ~s with ~w",
                     [inet:ntoa(From), inet:ntoa(To), Labels]),
            Msg = #pcep_msg_update{
                update_list = [
                    #pcep_update{
                        srp = #pcep_obj_srp{
                            srp_id = SRPID + 1,
                            tlvs = [#pcep_tlv_path_setup_type{pst = srte}]
                        },
                        lsp = LSP,
                        ero = make_ero(Labels)
                    }
                ]
            },
            gen_pcep_protocol:send(Proto, Msg),
            Data#data{srpid = SRPID + 1}
    end.

handle_reports(Data, []) ->
    {noreply, Data};
handle_reports(#data{plspid = CurrPLSPID} = Data, [Report | Rest]) ->
    #pcep_report{
        srp = _SRP,
        lsp = #pcep_obj_lsp{
            flag_d = D,
            plsp_id = PLSPID,
            status = Status,
            tlvs = [
                #pcep_tlv_ipv4_lsp_id{
                    source = Src,
                    endpoint = Dst
                }
            |_]
        } = LSP
    } = Report,

    case {D, CurrPLSPID}  of
        {false, _} ->
            log_info(Data, "Undelegated route from ~s to ~s status: ~w",
                     [inet:ntoa(Src), inet:ntoa(Dst), Status]),
            handle_reports(Data, Rest);
        {true, undefined} ->
            log_info(Data, "New delegated route from ~s to ~s status: ~w",
                     [inet:ntoa(Src), inet:ntoa(Dst), Status]),
            pcep_server_database:register(Src, Dst, self()),
            handle_reports(Data#data{plspid = PLSPID, srpid = 0, lsp = LSP}, Rest);
        {true, PLSPID} ->
            log_info(Data, "Delegated route from ~s to ~s status: ~w",
                     [inet:ntoa(Src), inet:ntoa(Dst), Status]),
            handle_reports(Data, Rest)
    end.

handle_requests(Data, []) ->
    {noreply, Data};
handle_requests(#data{proto = Proto} = Data, [Request | Rest]) ->
    %TODO: Check RP's P flag : https://tools.ietf.org/html/rfc5440#section-7.4
    %TODO: Check Endpoint(s)'s P flag : https://tools.ietf.org/html/rfc5440#section-7.6 
    #pcep_compreq{
        rp = RP,
        endpoints = [
            #pcep_endpoint{
                endpoint = #pcep_obj_endpoint_ipv4_addr{
                    source = Src,
                    destination = Dst
                }
            }
        ]
    } = Request,
    log_info(Data, "Received computation request for route from ~s to ~s",
              [inet:ntoa(Src), inet:ntoa(Dst)]),
    case pcep_server_database:resolve(Src, Dst) of
        error ->
            log_info(Data, "No route found from from ~s to ~s",
                     [inet:ntoa(Src), inet:ntoa(Dst)]),
            Resp = #pcep_msg_comprep{
                reply_list = [
                    #pcep_comprep{
                        rp = RP,
                        nopath = #pcep_obj_nopath{}
                    }
                ]
            },
            gen_pcep_protocol:send(Proto, Resp),
            handle_requests(Data, Rest);
        {ok, Labels} ->
            log_info(Data, "Computed route from ~s to ~s: ~w",
                     [inet:ntoa(Src), inet:ntoa(Dst), Labels]),
            Resp = #pcep_msg_comprep{
                reply_list = [
                    #pcep_comprep{
                        rp = RP,
                        endpoints = [
                            #pcep_endpoint{
                                paths = [
                                    #pcep_path{
                                        ero = make_ero(Labels)
                                    }
                                ]
                            }
                        ]
                    }
                ]
            },
            gen_pcep_protocol:send(Proto, Resp),
            handle_requests(Data, Rest)
    end.

make_ero(Labels) ->
    #pcep_obj_ero{
        path = [
            #pcep_ro_subobj_sr{
                has_sid = true,
                nai_type = ipv4_adjacency,
                is_mpls = true,
                sid = #mpls_stack_entry{
                    label = L
                }
            } || L <- Labels
        ]
    }.

handle_notifications(Data, []) ->
    {noreply, Data};
handle_notifications(Data, [_Notif | Rest]) ->
    log_debug(Data, "Received notification"),
    handle_notifications(Data, Rest).    

handle_errors(Data, []) ->
    {noreply, Data};
handle_errors(Data, [_Error | Rest]) ->
    log_debug(Data, "Received error"),
    handle_errors(Data, Rest).


%-- Handler Callbacks Functions ------------------------------------------------

handler_ready(#data{id = Id, handler = Handler, peer_caps = Caps} = Data) ->
    {ok, NewHandler} = gen_pcep_handler:ready(Id, Caps, Handler),
    {ok, Data#data{handler = NewHandler}}.

handler_terminate(#data{handler = undefined} = Data, _Reason) ->
    Data;
handler_terminate(#data{handler = Handler} = Data, Reason) ->
    gen_pcep_handler:terminate(Reason, Handler),
    Data#data{handler = undefined}.
