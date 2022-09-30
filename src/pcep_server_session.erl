-module(pcep_server_session).

%TODO: Implement OPEN negociation; When a negociable error is recevied during
%      handshake, and it contains an open object, we should send a second open
%      message and wait for one. If the second time negotiation fails we close
%      the connection.

%TODO: Open questions:
%       - Is the SRP given for all the state update reports from the PCC until is is up or active ?
%         It is not clearly defined in https://datatracker.ietf.org/doc/html/rfc8231#section-5.8.3
%       - What does bi-directional TE LSP means ???
%         https://datatracker.ietf.org/doc/html/rfc5440#section-7.4.1

-behaviour(gen_statem).
-behaviour(gen_pcep_proto_session).
-behaviour(pcep_server_session).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").
-include_lib("pcep_codec/include/pcep_codec.hrl").

-include("pcep_server.hrl").


%%% BEHAVIOUR %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-callback update_flow(pid(), FlowId :: flow_id(), Route :: te_route() )
    -> {ok, NewRoute :: te_route()}
     | {error, Reason :: term()}.

-callback initiate_flow(pid(), Route :: te_route_initiate() )
    -> {ok, Flow :: te_flow()}
     | {error, Reason :: term()}.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% API functions
-export([start_link/3]).

% Behaviour pcep_server_session functions
-export([update_flow/3]).
-export([initiate_flow/2]).

% Behaviour gen_pcep_proto_session functions
-export([connection_closed/1]).
-export([connection_error/2]).
-export([decoding_error/2]).
-export([decoding_warning/2]).
-export([encoding_error/2]).
-export([encoding_warning/2]).
-export([pcep_message/2]).

% Behaviour gen_statem functions
-export([init/1]).
-export([callback_mode/0]).
-export([handle_event/4]).
-export([terminate/3]).
-export([code_change/4]).


%%% Records %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(data, {
    tag,
    peer,
    proto,
    handler_pid,
    config,
    keepalive_timeout,
    deadtimer_timeout,
    peer_caps = [],
    sid,
    peer_msd,
    next_srp_id = 1,
    pending_reports = #{},
    sync_proc,
    flows
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

start_link(HandlerParams, Proto, Peer) ->
    gen_statem:start_link(?MODULE, [HandlerParams, Proto, Peer], []).


%%% Behaviour pcep_server_session FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_flow(Pid, FlowId, Route) ->
    gen_statem:call(Pid, {update_flow, FlowId, Route}).

initiate_flow(Pid, InitRoute) ->
    gen_statem:call(Pid, {initiate_flow, InitRoute}).


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


%%% Behaviour gen_statem FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([HandlerParams, Proto, Peer]) ->
    gen_pcep_protocol:link(Proto),
    {Addr, _} = Peer,
    Tag = list_to_binary(inet:ntoa(Addr)),
    Data = #data{
        tag = Tag,
        peer = Peer,
        proto = Proto,
        flows = pcep_server_flows:init(Peer)
    },
    log_info(Data, "Starting PCEP session"),
    {ok, openwait, handler_init(Data, HandlerParams)}.

callback_mode() -> [handle_event_function, state_enter].

%-- OPENWAIT STATE -------------------------------------------------------------
handle_event(enter, _, openwait, #data{proto = Proto} = Data) ->
    log_debug(Data, "Sending open message and waiting for peer's"),
    Timeout = get_config(Data, openwait_timeout),
    Msg = #pcep_msg_open{open = handshake_start(Data)},
    gen_pcep_protocol:send(Proto, Msg),
    {keep_state, Data, [{state_timeout, Timeout, openwait_timeout}]};
handle_event(state_timeout, openwait_timeout, openwait, Data) ->
    log_error(Data, "Handshake timed out waiting for open message, closing PCEP session"),
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
    {close, Data2} = handshake_errors(Data, Errors),
    stop_session(Data2, handshake_error);
handle_event(cast, {pcep, Msg}, openwait, Data) ->
    log_error(Data, "Unexpected PCEP message ~peer_caps received before OPEN",
              [element(1, Msg)]),
    stop_session(Data, handshake_error, session_failure, invalid_open_message);
%-- KEEPWAIT STATE -------------------------------------------------------------
handle_event(enter, _, keepwait, Data) ->
    log_debug(Data, "Sending first keep-alive message and waiting for peer's"),
    Timeout = get_config(Data, keepwait_timeout),
    send_keepalive(Data),
    {keep_state, Data, [
        {state_timeout, Timeout, keepwait_timeout}
    | update_keepalive(Data)]};
handle_event(cast, {pcep, #pcep_msg_keepalive{}}, keepwait, Data) ->
    handler_opened(Data),
    {next_state, synchronize, Data, update_deadtimer(Data)};
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             keepwait, Data) ->
    %TODO: Add support for negociation
    {close, Data2} = handshake_errors(Data, Errors),
    stop_session(Data2, handshake_error);
handle_event(state_timeout, keepwait_timeout, keepwait, Data) ->
    log_error(Data, "Handshake timed out waiting for keep-alive message, closing PCEP session"),
    stop_session(Data, handshake_error, session_failure,
                 keepalivewait_timed_out);
handle_event(cast, {pcep, Msg}, keepwait, Data) ->
    log_error(Data, "Unexpected PCEP message ~p received during handshake",
              [element(1, Msg)]),
    %TODO: The expected error value in this case is not clear.
    stop_session(Data, handshake_error, session_failure, session_failure);
%-- SYNCHRONIZE STATE ----------------------------------------------------------
handle_event(enter, _, synchronize, Data) ->
    Timeout = get_config(Data, sync_timeout),
    {keep_state, Data, [{state_timeout, Timeout, sync_timeout}]};
handle_event(cast, {pcep, #pcep_msg_report{report_list = Reports}},
             synchronize, Data) ->
    case synchronize_handle_reports(Data, Reports) of
        {stop, ErrT, ErrV} ->
            stop_session(Data, sync_error, ErrT, ErrV);
        {done, NewData} ->
            {next_state, sync_wait, NewData, update_deadtimer(Data)};
        {continue, NewData} ->
            {keep_state, NewData, update_deadtimer(Data)}
    end;
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             synchronize, Data) ->
    {stop, Data2} = synchronize_handle_errors(Data, Errors),
    stop_session(Data2, sync_error);
handle_event(cast, {pcep, Msg}, synchronize, Data) ->
    log_error(Data, "Unexpected PCEP message during sunchronization: ~p",
              [Msg]),
    %TODO: The expected error value in this case is not clear.
    stop_session(Data, sync_error, lsp_state_sync_error, lsp_state_sync_error);
handle_event(state_timeout, sync_timeout, synchronize, Data) ->
    log_error(Data, "Synchronization timed out, closing PCEP session"),
    %TODO: The expected error value in this case is not clear.
    stop_session(Data, sync_error, lsp_state_sync_error, lsp_state_sync_error);
%-- BOTH SYNCHRONIZE AND SYNC_WAIT STATES --------------------------------------
handle_event(info, {flow_addition_accepted, Flow, Args},
             State, Data) when State =:= synchronize; State =:= sync_wait ->
    case synchronize_flow_accepted(Data, Flow, Args) of
        {ok, NewData} -> {keep_state, NewData};
        {stop, ErrT, ErrV} -> stop_session(Data, sync_error, ErrT, ErrV)
    end;
handle_event(info, {flow_addition_rejected, Reason, Flow, Args},
             State, Data) when State =:= synchronize; State =:= sync_wait ->
    {stop, ErrT, ErrV} = synchronize_flow_rejected(Data, Reason, Flow, Args),
    stop_session(Data, sync_error, ErrT, ErrV);
%-- SYNC_WAIT STATE ------------------------------------------------------------
% We are waiting for all the synchronous flow synchronization calls to be done
handle_event(enter, _, sync_wait, _Data) ->
    %TODO: Maybe set a timeout so we don't get stuck in this state ?
    {keep_state_and_data, []};
handle_event(info, sync_done, sync_wait, Data) ->
    {next_state, ready, Data};
handle_event(cast, {pcep, _}, sync_wait, _Data) ->
    % Keep all the pcep messages for when the synchronization is done
    {keep_state_and_data, [postpone]};
%-- READY STATE ----------------------------------------------------------------
handle_event(enter, _, ready, Data) ->
    handler_ready(Data),
    {keep_state_and_data, []};
handle_event({call, From}, {update_flow, FlowId, Route}, ready, Data) ->
    NewData = initiate_flow_update(Data, FlowId, Route, From),
    {keep_state, NewData};
handle_event({call, From}, {initiate_flow, InitRoute}, ready, Data) ->
    NewData = initiate_flow_initiate(Data, InitRoute, From),
    {keep_state, NewData};
handle_event(cast, {pcep, #pcep_msg_report{report_list = Reports}},
             ready, Data) ->
    {ok, NewData} = ready_handle_reports(Data, Reports),
    {keep_state, NewData, update_deadtimer(Data)};
handle_event(cast, {pcep, #pcep_msg_compreq{request_list = Requests}},
             ready, Data) ->
    {ok, NewData} = ready_handle_requests(Data, Requests),
    {keep_state, NewData, update_deadtimer(Data)};
handle_event(cast, {pcep, #pcep_msg_notif{notif_list = Notifications}},
             ready, Data) ->
    {ok, NewData} = ready_handle_notifications(Data, Notifications),
    {keep_state, NewData, update_deadtimer(Data)};
handle_event(cast, {pcep, #pcep_msg_error{error_list = Errors}},
             ready, Data) ->
    {ok, NewData} = ready_handle_errors(Data, Errors),
    {keep_state, NewData, update_deadtimer(Data)};
handle_event(info, {route_request_succeed, Route, Args}, ready, Data) ->
    {ok, Data2} = ready_request_succeed(Data, Route, Args),
    {keep_state, Data2};
handle_event(info, {route_request_failed, Reason, Constraints, Args},
             ready, Data) ->
    {ok, Data2} = ready_request_failed(Data, Reason, Constraints, Args),
    {keep_state, Data2};
handle_event(info, {flow_addition_accepted, Flow, Args}, ready, Data) ->
    {ok, Data2} = ready_flow_accepted(Data, Flow, Args),
    {keep_state, Data2};
handle_event(info, {flow_addition_rejected, Reason, Flow, Args}, ready, Data) ->
    {ok, Data2} = ready_flow_rejected(Data, Reason, Flow, Args),
    {keep_state, Data2};
handle_event(info, {flow_init_accepted, _Flow, _Args}, ready, Data) ->
    {keep_state, Data};
handle_event(info, {flow_delegation_acccepted, Flow, Args}, ready, Data) ->
    {ok, Data2} = ready_delegation_accepted(Data, Flow, Args),
    {keep_state, Data2};
handle_event(info, {flow_delegation_rejected, Reason, Flow, Args},
             ready, Data) ->
    {ok, Data2} = ready_delegation_rejected(Data, Reason, Flow, Args),
    {keep_state, Data2};
%-- ANY STATE ------------------------------------------------------------------
handle_event(cast, {pcep, #pcep_msg_close{close = Close}}, _State, Data) ->
    Reason = Close#pcep_obj_close.reason,
    log_info(Data, "PCEP Session closed by peer: ~p", [Reason]),
    stop_session(Data, closed);
handle_event(cast, {pcep, #pcep_msg_keepalive{}}, _State, Data) ->
    {keep_state, Data, update_deadtimer(Data)};
handle_event(cast, {pcep, Msg}, _State, Data) ->
    log_warn(Data, "Session received unexpected PCEP message: ~p", [Msg]),
    %TODO: Limit the rate of unknown messages
    {keep_state_and_data, update_deadtimer(Data)};
handle_event({timeout, keepalive}, keepalive, _State, Data) ->
    send_keepalive(Data),
    {keep_state, Data, update_keepalive(Data)};
handle_event({timeout, deadtimer}, deadtimer, _State, Data) ->
    log_error(Data, "No activity detected, closing PCEP session"),
    stop_session(Data, activity_timeout);
handle_event(cast, connection_closed, _State, Data) ->
    log_info(Data, "Connection closed by peer"),
    stop_session(Data, closed);
handle_event(cast, {warn, _, _Warn}, _State, Data) ->
    % Disable warning due to usupported TLV 65505 noise
    %log_warn(Data, Warn),
    {keep_state, Data};
handle_event(cast, {error, connection, Reason}, _State, Data) ->
    log_info(Data, "Connection error ~p", [Reason]),
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
    log_debug(Data, "PCEP session received unexpected ~w event in state ~w: ~p",
              [EventType, State, EventContent]),
    {keep_state, Data}.

terminate(Reason, _State, Data) ->
    handler_terminate(Data, Reason),
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%-- Logging Utility Functions --------------------------------------------------

log_debug(#data{tag = Tag}, Fmt) when is_list(Fmt)->
    logger:debug("[~s] " ++ Fmt, [Tag]).

log_debug(#data{tag = Tag}, Fmt, Args) ->
    logger:debug("[~s] " ++ Fmt, [Tag | Args]).

log_info(#data{tag = Tag}, Fmt) ->
    logger:info("[~s] " ++ Fmt, [Tag]).

log_info(#data{tag = Tag}, Fmt, Args) ->
    logger:info("[~s] " ++ Fmt, [Tag | Args]).

log_warn(#data{tag = Tag}, Map) when is_map(Map) ->
    logger:warning(Map#{peer => Tag}).

log_warn(#data{tag = Tag}, Fmt, Args) ->
    logger:warning("[~s] " ++ Fmt, [Tag | Args]).

log_error(#data{peer = Peer}, Map) when is_map(Map) ->
    logger:error(Map#{peer => Peer});
log_error(#data{tag = Tag}, Fmt) ->
    logger:info("[~s] " ++ Fmt, [Tag]).

log_error(#data{tag = Tag}, Fmt, Args) ->
    logger:error("[~s] " ++ Fmt, [Tag | Args]).


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

get_config(#data{config = Map}, Key) -> maps:get(Key, Map).

stop_session(#data{proto = Proto} = Data, Reason) ->
    handler_terminate(Data, Reason),
    gen_pcep_protocol:close(Proto),
    {stop, normal, Data}.

stop_session(#data{proto = Proto} = Data, Reason, ErrC, ErrV) ->
    handler_terminate(Data, Reason),
    Msg = pcep_error_msg(ErrC, ErrV),
    gen_pcep_protocol:send(Proto, Msg),
    gen_pcep_protocol:close(Proto),
    {stop, normal, Data}.

pcep_error_msg(ErrT, ErrV) ->
    #pcep_msg_error{
        error_list = [
            #pcep_error{errors = [#pcep_obj_error{type = ErrT, value = ErrV}]}
        ]
    }.

flow_ident({_PccId, FlowId}) -> io_lib:format("~w", [FlowId]);
flow_ident(#{id := Id, name := <<>>}) -> io_lib:format("~w", [Id]);
flow_ident(#{id := Id, name := Name}) -> io_lib:format("~s (~w)", [Name, Id]).

check_has_ident(#pcep_report{lsp = #pcep_obj_lsp{tlvs = Tlvs}}) ->
    case pcep_server_utils:lookup_tlv(
                [pcep_tlv_ipv4_lsp_id, pcep_tlv_ipv6_lsp_id], Tlvs) of
        error -> {error, mandatory_object_missing, lsp_id_tlv_missing};
        _ -> ok
    end.


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


%-- Handshake Functions --------------------------------------------------------

check(_Obj, []) -> ok;
check(Obj, [Fun | Rest]) ->
    case Fun(Obj) of
        {error, _ErrT, _ErrV} = Error -> Error;
        ok -> check(Obj, Rest)
    end.

handshake_start(Data) ->
    KeepaliveTimeout = get_config(Data, keepalive_timeout),
    DeadtimerTimeout = get_config(Data, deadtimer_timeout),
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

check_stateful(Data, Open, Status) ->
    ReqCaps = get_config(Data, required_caps),
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

check_srte(Data, Open, Status) ->
    ReqCaps = get_config(Data, required_caps),
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
        {NewStatus, NewOpen, NewData} ->
            handshake_apply(NewData, NewOpen, NewStatus, Rest)
    end.

handshake_negotiate(#data{tag = Tag} = Data, Open) ->
    case handshake_apply(Data, Open,
                         [fun check_stateful/3, fun check_srte/3]) of
        {done, Data2} ->
            Sid = Open#pcep_obj_open.sid,
            SidBin = integer_to_binary(Sid),
            Tag2 = <<Tag/binary,$:,SidBin/binary>>,
            Data3 = Data2#data{
                sid = Sid,
                tag = Tag2,
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
    log_error(Data, "Handshake error: ~p", [Error]),
    handshake_errors(Data, Rest).


%-- Synchronization Functions --------------------------------------------------

synchronize_handle_reports(Data, []) ->
    {continue, Data};
synchronize_handle_reports(Data, [#pcep_report{
        lsp = #pcep_obj_lsp{flag_s = false, plsp_id = 0}}]) ->
    % We could check there is:
    %  - no symbolic-path-name TLV
    %  - the lsp-identifiers TLV is all zero
    %  - there is an empty ERO object
    %  - there is no RRO object
    handler_checkpoint(Data, sync_done),
    {done, Data};
synchronize_handle_reports(Data, [#pcep_report{
        lsp = #pcep_obj_lsp{flag_s = true}} = Report | Rest]) ->
    case synchronize_handle_report(Data, Report) of
        {ok, Data2} -> synchronize_handle_reports(Data2, Rest);
        {error, ErrT, ErrV} -> {stop, ErrT, ErrV}
    end;
synchronize_handle_reports(Data, _) ->
    log_error(Data, "Invalid reports received during synchronization"),
    {stop, lsp_state_sync_error, pce_cant_process_lsp_report}.

synchronize_handle_report(#data{flows = Flows} = Data, Report) ->
    %TODO: check the report do not have a non-null SRP, an rro, an iro,
    %      actual_bandwidth or actual_metrics
    %TODO: check pcep_tlv_path_setup_type is srte
    case check(Report, [fun check_has_ident/1]) of
        {error, _ErrT, _ErrV} = Error -> Error;
        ok ->
            %TODO: handle flow unpacking errors
            {ok, Flow} = pcep_server_flows:report_to_flow(Flows, Report),
            log_debug(Data, "Flow ~s received for synchronization",
                      [flow_ident(Flow)]),
            handler_flow_added(Data, Flow, Report),
            {ok, Data}
    end.

synchronize_flow_accepted(#data{flows = Flows} = Data, Flow, _Report) ->
    log_info(Data, "Flow ~s synchronization accepted", [flow_ident(Flow)]),
    Flows2 = pcep_server_flows:add_flow(Flows, Flow),
    {ok, Data#data{flows = Flows2}}.

synchronize_flow_rejected(Data, Reason, Flow, _Report) ->
    log_error(Data, "Flow ~s rejected during synchronization: ~p",
              [flow_ident(Flow), Reason]),
    % TODO: The error value is not clear in this usecase
    {stop, lsp_state_sync_error, lsp_state_sync_error, Data}.

synchronize_handle_errors(Data, []) ->
    {stop, Data};
synchronize_handle_errors(Data, [Error | Rest]) ->
    log_error(Data, "Synchronization error: ~p", [Error]),
    synchronize_handle_errors(Data, Rest).


%-- PCEP Message Handlers ------------------------------------------------------

ready_handle_reports(Data, []) ->
    {ok, Data};
ready_handle_reports(#data{proto = Proto} = Data, [Report | Rest]) ->
    %TODO: return error if statefull capabiliti is not supported : https://tools.ietf.org/html/rfc8231#section-5.4
    case ready_handle_report(Data, Report) of
        {ok, Data2} ->
            ready_handle_reports(Data2, Rest);
        {error, ErrT, ErrV} ->
            Msg = pcep_error_msg(ErrT, ErrV),
            gen_pcep_protocol:send(Proto, Msg),
            ready_handle_reports(Data, Rest)
    end.

ready_handle_report(#data{flows = Flows, pending_reports = RepMap} = Data,
                    Report) ->
    case pcep_server_flows:report_srp_id(Flows, Report) of
        undefined -> ready_handle_generic_report(Data, Report);
        SrpId ->
            case maps:find(SrpId, RepMap) of
                error ->
                    ready_handle_unknown_srp_report(Data, SrpId, Report);
                {ok, {{update, FlowId}, From}} ->
                    ready_handle_update_report(#data{flows = Flows} = Data, SrpId, FlowId, From, Report);
                {ok, {initiate, From}} ->
                    ready_handle_initiate_report(#data{flows = Flows} = Data, SrpId, From, Report)
            end
    end.

ready_handle_unknown_flow_report(#data{flows = Flows} = Data, Report) ->
    case check(Report, [fun check_has_ident/1]) of
        {error, _ErrT, _ErrV} = Error ->
            Error;
        ok ->
            %TODO: handle flow unpacking errors
            {ok, Flow} = pcep_server_flows:report_to_flow(Flows, Report),
            handler_flow_added(Data, Flow, Report),
            {ok, Data}
    end.

ready_handle_unknown_srp_report(#data{flows = Flows} = Data, SrpId, Report) ->
    case pcep_server_flows:report_to_events(Flows, Report) of
        %TODO: handle flow unpacking errors
        %TODO: Handle maximum rate of error
        {error, not_found} ->
            % First time we are seeing this flow
            ready_handle_unknown_flow_report(Data, Report);
        {ok, Flow, Events} ->
            %TODO: Shouldn't that fail ?
            %      We are receiving reports with unknown SRP from FRR,
            %      needs more investigation.
            log_debug(Data, "Received report for flow ~s update ~w, with events ~p",
                      [flow_ident(Flow), SrpId, Events]),
            Flows2 = pcep_server_flows:update_flow(Flows, Flow),
            ready_handle_report_events(Data#data{flows = Flows2}, Flow, Events)
    end.


ready_handle_generic_report(#data{flows = Flows} = Data, Report) ->
    case pcep_server_flows:report_to_events(Flows, Report) of
        %TODO: handle flow unpacking errors
        %TODO: Handle maximum rate of error
        {error, not_found} ->
            % First time we are seeing this flow
            ready_handle_unknown_flow_report(Data, Report);
        {ok, Flow, Events} ->
            log_debug(Data, "Received report for flow ~s, got events ~p",
                      [flow_ident(Flow), Events]),
            Flows2 = pcep_server_flows:update_flow(Flows, Flow),
            ready_handle_report_events(Data#data{flows = Flows2}, Flow, Events)
    end.


ready_handle_update_report(#data{flows = Flows, pending_reports = RepMap} = Data,
                           SrpId, FlowId, From, Report) ->
    case pcep_server_flows:report_to_events(Flows, Report) of
        %TODO: handle flow unpacking errors
        %TODO: Handle maximum rate of error
        {error, not_found} ->
            % First time we are seeing this flow
            ready_handle_unknown_flow_report(Data, Report);
        {ok, #{id := FlowId, route := Route} = Flow, Events} ->
            Flows2 = pcep_server_flows:update_flow(Flows, Flow),
            log_debug(Data, "Received report ~w for flow ~s pending update, got events ~p",
                      [SrpId, flow_ident(Flow), Events]),
            case ready_handle_update_events(Data#data{flows = Flows2},
                                            Flow, Events) of
                {done, Data2} ->
                    gen_statem:reply(From, {ok, Route}),
                    RepMap2 = maps:remove(SrpId, RepMap),
                    {ok, Data2#data{pending_reports = RepMap2}};
                {wait, Data2} ->
                    {ok, Data2}
            end
    end.

ready_handle_initiate_report(#data{flows = Flows, pending_reports = RepMap} = Data,
                             SrpId, From, Report) ->
    FlowId = pcep_server_flows:report_id(Flows, Report),
    {Data3, Result} = case pcep_server_flows:has_flow(Flows, FlowId) of
        false ->
            {ok, Flow} = pcep_server_flows:report_to_flow(Flows, Report),
            %TODO: handle flow unpacking errors
            log_debug(Data, "Received first report ~w for initiated active flow ~s",
                      [SrpId, flow_ident(Flow)]),
            Flows2 = pcep_server_flows:add_flow(Flows, Flow),
            Data2 = Data#data{flows = Flows2},
            handler_flow_initiated(Data2, Flow, Report),
            case Flow of
                #{is_active := false, status := up} -> {Data2, {ok, Flow}};
                #{is_active := true, status := active} -> {Data2, {ok, Flow}};
                _ -> {Data2, undefined}
            end;
        true ->
            {ok, Flow, Events} = pcep_server_flows:report_to_events(Flows, Report),
            log_debug(Data, "Received new report ~w for initiated active flow ~s",
                      [SrpId, flow_ident(FlowId)]),
            Flows2 = pcep_server_flows:update_flow(Flows, Flow),
            case ready_handle_update_events(Data#data{flows = Flows2},
                                            Flow, Events) of
                {done, Data2} -> {Data2, {ok, Flow}};
                {wait, Data2} -> {Data2, undefined}
            end
    end,
    case Result of
        undefined ->
            {ok, Data3};
        _ ->
            gen_statem:reply(From, Result),
            RepMap2 = maps:remove(SrpId, RepMap),
            {ok, Data3#data{pending_reports = RepMap2}}
    end.

ready_handle_report_events(Data, _Flow, []) ->
    {ok, Data};
ready_handle_report_events(Data, #{id := FlowId} = Flow,
                           [{flow_status_changed, New} | Rest]) ->
    Data2 = hack_for_pcc_not_puting_the_srp_in_all_reports(Data, Flow, New),
    handler_flow_status_changed(Data2, FlowId, New),
    ready_handle_report_events(Data2, Flow, Rest);
ready_handle_report_events(Data, Flow,
                           [{flow_route_changed, Route} | Rest]) ->
    log_error(Data, "Unexpected route change for flow ~s: ~p",
              [flow_ident(Flow), Route]),
    ready_handle_report_events(Data, Flow, Rest);
ready_handle_report_events(Data, Flow, [_ | Rest]) ->
    ready_handle_report_events(Data, Flow, Rest).


%FIXME: pathd is not sending a SRP with all the status change reports,
%       only the first one. So if there is a pending update and we get
%       a status update without SRP for the flow, andles it as if there was one.
%       NOT EFFICIENT AT ALL, SHOULD BE FIXED IN PATHD
hack_for_pcc_not_puting_the_srp_in_all_reports(
        #data{pending_reports = RepMap} = Data,
        #{id := FlowId, is_active := IsActive, route := Route},
        NewStatus)
  when IsActive =:= true, NewStatus =:= active;
       IsActive =:= false, NewStatus =:= up ->
    case [{K, F} || {K, {{update, I}, F}} <- maps:to_list(RepMap), I =:= FlowId] of
        [] -> Data;
        [{Key, From}] ->
            gen_statem:reply(From, {ok, Route}),
            Data#data{pending_reports = maps:remove(Key, RepMap)}
    end;
hack_for_pcc_not_puting_the_srp_in_all_reports(Data, _Flow, _NewStatus) ->
    Data.

ready_handle_update_events(Data, _Flow, []) ->
    {wait, Data};
ready_handle_update_events(Data, #{is_active := true},
                           [{flow_status_changed, active} | _Rest]) ->
    {done, Data};
ready_handle_update_events(Data, #{is_active := false},
                           [{flow_status_changed, up} | _Rest]) ->
    {done, Data};
ready_handle_update_events(Data, Flow, [_ | Rest]) ->
    ready_handle_update_events(Data, Flow, Rest).


ready_flow_accepted(#data{flows = Flows} = Data,
                    #{is_delegated := true} = Flow, _Report) ->
    log_info(Data, "Added flow ~s accepted, acknowledging delegation",
             [flow_ident(Flow)]),
    % Delegated flow as been accepted, we need to send an ACK report
    Flows2 = pcep_server_flows:add_flow(Flows, Flow),
    {ok, send_update(Data#data{flows = Flows2}, Flow)};
ready_flow_accepted(#data{flows = Flows} = Data, Flow, _Report) ->
    log_info(Data, "Added flow ~s accepted", [flow_ident(Flow)]),
    % A non-delegated flow has been accepted, no ACK report required
    Flows2 = pcep_server_flows:add_flow(Flows, Flow),
    {ok, Data#data{flows = Flows2}}.

ready_flow_rejected(#data{flows = Flows} = Data,
                    Reason, #{is_delegated := true } = Flow, _Report) ->
    %TODO: Assum delegation is regected, add support for other errors
    log_error(Data, "Added flow ~s delegation rejected: ~p",
              [flow_ident(Flow), Reason]),
    Flow2 = Flow#{is_delegated => false},
    Flows2 = pcep_server_flows:add_flow(Flows, Flow2),
    {ok, send_update(Data#data{flows = Flows2}, Flow2)}.

ready_delegation_accepted(#data{flows = Flows} = Data, Flow, _Args) ->
    log_info(Data, "Flow ~s delegation accepted", [flow_ident(Flow)]),
    Flow2 = Flow#{is_delegated => true},
    Flows2 = pcep_server_flows:update_flow(Flows, Flow2),
    {ok, send_update(Data#data{flows = Flows2}, Flow2)}.

ready_delegation_rejected(#data{flows = Flows} = Data, Reason, Flow, _Args) ->
    log_error(Data, "Flow ~s delegation rejected: ~p",
              [flow_ident(Flow), Reason]),
    Flow2 = Flow#{is_delegated => false},
    Flows2 = pcep_server_flows:update_flow(Flows, Flow2),
    {ok, send_update(Data#data{flows = Flows2}, Flow2)}.

send_update(#data{proto = Proto, flows = Flows, next_srp_id = SrpId} = Data, Flow) ->
    {ok, Up} = pcep_server_flows:flow_to_update(Flows, SrpId, Flow),
    Msg = #pcep_msg_update{update_list = [Up]},
    gen_pcep_protocol:send(Proto, Msg),
    Data#data{next_srp_id = SrpId + 1}.

ready_handle_requests(Data, []) ->
    {ok, Data};
ready_handle_requests(Data, [Request | Rest]) ->
    case ready_handle_request(Data, Request) of
        {ok, Data2} -> ready_handle_requests(Data2, Rest)
    end.

ready_handle_request(#data{flows = Flows} = Data, Request) ->
    case pcep_server_flows:unpack_compreq(Flows, Request) of
        %TODO: handle the requests with LSP object
        %TODO: If there is an associated flow, check it is not already delegated
        {request_flow, #{source := S, destination := D} = TeReq, undefined} ->
            log_info(Data, "Received computation request for path between ~s and ~s",
                     [inet:ntoa(S), inet:ntoa(D)]),
            handler_requeste_route(Data, TeReq, Request),
            {ok, Data}
    end.

ready_request_succeed(#data{proto = Proto, flows = Flows} = Data,
                      Route, PcepReq) ->
    #{source := S, destination := D} = Route,
    log_info(Data, "Route request from ~s to ~s succeed: ~p",
             [inet:ntoa(S), inet:ntoa(D), route_to_labels(Route)]),
    %TODO: If the request is associated with a flow we should add it to the cache
    {ok, CompRep} = pcep_server_flows:pack_comprep(Flows, PcepReq, Route),
    Msg = #pcep_msg_comprep{reply_list = [CompRep]},
    gen_pcep_protocol:send(Proto, Msg),
    {ok, Data}.

ready_request_failed(#data{proto = Proto, flows = Flows} = Data,
                     Reason, Constraints, PcepReq) ->
    log_error(Data, "Route request failed: ~p", [Reason]),
    {ok, CompRep} =
        pcep_server_flows:pack_nopath(Flows, PcepReq, Reason, Constraints),
    Msg = #pcep_msg_comprep{reply_list = [CompRep]},
    gen_pcep_protocol:send(Proto, Msg),
    {ok, Data}.

ready_handle_notifications(Data, []) ->
    {ok, Data};
ready_handle_notifications(Data, [_Notif | Rest]) ->
    log_debug(Data, "Received notification"),
    ready_handle_notifications(Data, Rest).

ready_handle_errors(Data, []) ->
    {ok, Data};
ready_handle_errors(Data, [Error | Rest]) ->
    Data2 = ready_handle_error(Data, Error),
    ready_handle_errors(Data2, Rest).

ready_handle_error(#data{pending_reports = RepMap} = Data,
                   #pcep_error{id_list = Ids, errors = Errors}) ->
    %TODO: Close the session if required ?
    case [I || #pcep_obj_srp{srp_id = I} <- Ids] of
        [] ->
            log_warn(Data, "Received errors: ~s",
                     [lists:join(", ", [io_lib:format("~w/~w", [T, V])
                                        || #pcep_obj_error{type = T, value = V}
                                        <- Errors])]),
            Data;
        SrpIds ->
            log_warn(Data, "Received errors for update(s) ~s: ~s",
                     [lists:join(", ", [io_lib:format("~w", [I])
                                        || I <- SrpIds]),
                      lists:join(", ", [io_lib:format("~w/~w", [T, V])
                                        || #pcep_obj_error{type = T, value = V}
                                        <- Errors])]),
            RepMap2 = lists:foldl(
                fun(I, M) ->
                    case maps:take(I, M) of
                        error -> M;
                        {{_, From}, M2} ->
                            %TODO: More detailed error reason ?
                            gen_statem:reply(From, {error, update_error}),
                            M2
                    end
                end, RepMap, SrpIds),
            Data#data{pending_reports = RepMap2}
    end.


%-- Flow Update Functions ------------------------------------------------------

initiate_flow_update(Data, FlowId, Route, From) ->
    #data{proto = Proto, flows = Flows, next_srp_id = SrpId,
          pending_reports = RepMap} = Data,
    {ok, Update} = pcep_server_flows:pack_update(Flows, SrpId, FlowId, Route),
    Msg = #pcep_msg_update{update_list = [Update]},
    gen_pcep_protocol:send(Proto, Msg),
    %TODO: add support for srp_id wrap around from 0xFFFFFFFE to 0x00000001
    Data#data{pending_reports = RepMap#{SrpId => {{update, FlowId}, From}},
              next_srp_id = SrpId + 1}.


%-- Flow Initiate Functions ----------------------------------------------------

initiate_flow_initiate(Data, InitRoute, From) ->
    #data{proto = Proto, flows = Flows, next_srp_id = SrpId,
          pending_reports = RepMap} = Data,
    {ok, Initiate} = pcep_server_flows:pack_initiate(Flows, SrpId, InitRoute),
    Msg = #pcep_msg_initiate{action_list = [Initiate]},
    gen_pcep_protocol:send(Proto, Msg),
    %TODO: add support for srp_id wrap around from 0xFFFFFFFE to 0x00000001
    Data#data{pending_reports = RepMap#{SrpId => {initiate, From}},
              next_srp_id = SrpId + 1}.


%-- Handler Interface Functions ------------------------------------------------

handler_init(#data{handler_pid = undefined} = Data, Params) ->
    Self = self(),
    Pid = erlang:spawn_link(fun() ->
        handler_bootstrap(Self, Params)
    end),
    Config = receive {handler_ready, C} -> C end,
    Data#data{handler_pid = Pid, config = Config}.

handler_checkpoint(#data{handler_pid = Pid}, Checkpoint) ->
    Pid ! {checkpoint, Checkpoint}.

% handler_call(#data{handler_pid = Pid} = Data, Msg) ->
%     % TODO: Add some timeout ?
%     Ref = erlang:make_ref(),
%     Pid ! {call, Ref, Msg},
%     receive {reply, Ref, Reply} -> Reply end.

handler_opened(#data{peer = {Id, _}, handler_pid = Pid, peer_caps = Caps}) ->
    Pid ! {opened, Id, Caps, self()}.

handler_flow_initiated(#data{handler_pid = Pid}, Flow, Args) ->
    Pid ! {flow_initiated, Flow, Args}.

handler_flow_added(#data{handler_pid = Pid}, Flow, Args) ->
    Pid ! {flow_added, Flow, Args}.

handler_ready(#data{handler_pid = Pid}) ->
    Pid ! ready.

handler_requeste_route(#data{handler_pid = Pid}, Req, Args) ->
    Pid ! {request_route, Req, Args}.

handler_flow_delegated(#data{handler_pid = Pid}, Flow, Args) ->
    Pid ! {flow_delegated, Flow, Args}.

handler_flow_status_changed(#data{handler_pid = Pid}, FlowId, NewStatus) ->
    Pid ! {flow_status_changed, FlowId, NewStatus}.

handler_terminate(#data{handler_pid = undefined}, _Reason) -> ok;
handler_terminate(#data{handler_pid = Pid}, Reason) ->
    MonRef = erlang:monitor(process, Pid),
    Pid ! {terminate, Reason},
    receive
        handler_terminated ->
            erlang:demonitor(MonRef, [flush]),
            ok;
        {'DOWN', MonRef, process, Pid, _Reason} ->
            ok
    end.

handler_bootstrap(Parent, Params) ->
    {ok, Opts, State} = gen_pcep_handler:init(Params),
    OpenWaitTimeout = maps:get(openwait_timeout, Opts,
                               ?DEFAULT_OPENWAIT_TIMEOUT),
    KeepWaitTimeout = maps:get(keepwait_timeout, Opts,
                               ?DEFAULT_KEEPWAIT_TIMEOUT),
    SyncTimeout = maps:get(sync_timeout, Opts,
                           ?DEFAULT_SYNC_TIMEOUT),
    KeepaliveTimeout = get_bounded(
        maps:get(keepalive_timeout, Opts, undefined),
        ?DEFAULT_KEEPALIVE_TIMEOUT, ?MIN_KEEPALIVE_TIMEOUT,
        ?MAX_KEEPALIVE_TIMEOUT),
    DeadtimerTimeout = get_bounded(
        maps:get(deadtimer_timeout, Opts, undefined),
        ?DEFAULT_DEADTIMER_TIMEOUT, ?MIN_DEADTIMER_TIMEOUT,
        ?MAX_DEADTIMER_TIMEOUT),
    RequiredCaps = maps:get(required_capabilities, Opts,
                            [stateful, lsp_update]),
    Config = #{
        openwait_timeout => OpenWaitTimeout,
        keepwait_timeout => KeepWaitTimeout,
        sync_timeout => SyncTimeout,
        keepalive_timeout => KeepaliveTimeout,
        deadtimer_timeout => DeadtimerTimeout,
        required_caps => RequiredCaps
    },
    Parent ! {handler_ready, Config},
    handler_loop(Parent, State).

handler_loop(Parent, State) ->
    receive
        {checkpoint, Checkpoint} ->
            Parent ! Checkpoint,
            handler_loop(Parent, State);
        {opened, Id, Caps, Sess} ->
            {ok, NewState} = gen_pcep_handler:opened(Id, Caps, Sess, State),
            handler_loop(Parent, NewState);
        {flow_added, Flow, Args} ->
            case gen_pcep_handler:flow_added(Flow, State) of
                {ok, NewState} ->
                    Parent ! {flow_addition_accepted, Flow, Args},
                    handler_loop(Parent, NewState);
                {error, Reason} ->
                    Parent ! {flow_addition_rejected, Reason, Flow, Args},
                    handler_loop(Parent, State)
            end;
        {flow_initiated, Flow, Args} ->
            {ok, NewState} = gen_pcep_handler:flow_initiated(Flow, State),
            Parent ! {flow_init_accepted, Flow, Args},
            handler_loop(Parent, NewState);
        {request_route, Req, Args} ->
            case gen_pcep_handler:request_route(Req, State) of
                {ok, Route, NewState} ->
                    Parent ! {route_request_succeed, Route, Args},
                    handler_loop(Parent, NewState);
                {error, Reason} ->
                    Parent ! {route_request_failed, Reason, [], Args},
                    handler_loop(Parent, State);
                {error, Reason, Constr} ->
                    Parent ! {route_request_failed, Reason, Constr, Args},
                    handler_loop(Parent, State)
            end;
        {flow_delegated, Flow, Args} ->
            case gen_pcep_handler:flow_delegated(Flow, State) of
                {ok, NewState} ->
                    Parent ! {flow_delegation_accepted, Flow, Args},
                    handler_loop(Parent, NewState);
                {error, Reason} ->
                    Parent ! {flow_delegation_rejected, Reason, Flow, Args},
                    handler_loop(Parent, State)
            end;
        {flow_status_changed, FlowId, NewStatus} ->
            {ok, NewState} =
                gen_pcep_handler:flow_status_changed(FlowId, NewStatus, State),
            handler_loop(Parent, NewState);
        ready ->
            {ok, NewState} = gen_pcep_handler:ready(State),
            handler_loop(Parent, NewState);
        {terminate, Reason} ->
            gen_pcep_handler:terminate(Reason, State),
            Parent ! handler_terminated
    end.


%-- Utility Functions ----------------------------------------------------------

%TODO: Duplicated in epce_server.erl
route_to_labels(#{steps := Steps}) ->
    [Sid#mpls_stack_entry.label || #{sid := Sid} <- Steps].
