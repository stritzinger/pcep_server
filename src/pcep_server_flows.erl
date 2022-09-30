-module(pcep_server_flows).

%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").
-include_lib("pcep_codec/include/pcep_codec.hrl").


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% API functions
-export([init/1]).
-export([report_srp_id/2]).
-export([report_id/2]).
-export([has_flow/2]).
-export([add_flow/2]).
-export([update_flow/2]).
-export([report_to_flow/2]).
-export([flow_to_update/3]).
-export([refine_flow/2]).
-export([report_to_events/2]).
-export([unpack_compreq/2]).
-export([pack_nopath/4]).
-export([pack_comprep/3]).
-export([pack_update/4]).
-export([pack_initiate/3]).


%%% Records %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    pcc_id,
    cache = #{}
}).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({Addr, 4189}) -> #state{pcc_id = Addr}.

report_srp_id(_State, #pcep_report{srp = Srp}) ->
    case Srp of
        #pcep_obj_srp{srp_id = 0} -> undefined;
        #pcep_obj_srp{srp_id = V} -> V;
        _ -> undefine
    end.

report_id(#state{pcc_id = PccId}, #pcep_report{lsp = Lsp}) ->
    #pcep_obj_lsp{plsp_id = Id} = Lsp,
    {PccId, Id}.

has_flow(#state{cache = Cache}, FlowId) ->
    maps:find(FlowId, Cache) =/= error.

add_flow(#state{cache = Cache} = State, #{id := Key} = Flow) ->
    error = maps:find(Key, Cache),
    State#state{cache = Cache#{Key => Flow}}.

update_flow(#state{cache = Cache} = State, #{id := Key} = Flow) ->
    {ok, _} = maps:find(Key, Cache),
    State#state{cache = Cache#{Key => Flow}}.

report_to_flow(#state{pcc_id = PccId} = State, Report) ->
    apply_until_error(State, Report, #{owner => PccId}, [
        fun report_to_flow_lsp/3,
        fun report_to_flow_ero/3,
        fun report_to_flow_lspa/3,
        fun report_to_flow_bw/3,
        fun report_to_flow_metrics/3
    ]).

refine_flow(#state{cache = Cache}, #{id := Id, route := Route} = Flow) ->
    case maps:find(Id, Cache) of
        error -> Flow;
        {ok, #{route := RefRoute} = RefFlow} ->
            Route2 = map_override(Route, RefRoute, [source, destination]),
            map_override(Flow#{route => Route2}, RefFlow, [name])
    end.

report_to_events(#state{cache = Cache} = State,
                 #pcep_report{lsp = Lsp} = Report) ->
    case report_to_flow(State, Report) of
        %TODO: Handle unpacking errors
        {ok, #{id := Id, route := Route} = Flow} ->
            case maps:find(Id, Cache) of
                error -> {error, not_found};
                {ok, #{route := RefRoute} = RefFlow} ->
                    % Refine in place
                    Route2 = map_override(Route, RefRoute, [source, destination]),
                    Flow2 = map_override(Flow#{route => Route2}, RefFlow, [name]),
                    % Check for unexpected changes
                    case {map_changes(Flow2, RefFlow,
                            [is_active, name]),
                          map_changes(Route2, RefRoute,
                            [source, destination, constraints])} of
                        {[], []} ->
                            Events = check_for_events([], RefFlow, Lsp, [
                                fun check_for_status_change/3,
                                fun check_for_delegation/3,
                                fun check_for_removal/3
                            ]),
                            Events2 = check_for_events(Events, RefFlow, Flow2, [
                                fun check_for_route_change/3
                            ]),
                            {ok, Flow2, Events2};
                        {FlowKeys, RouteKeys} ->
                            {error, {unexpected_changes, FlowKeys ++ RouteKeys}}
                    end
            end
    end.

flow_to_update(#state{pcc_id = PccId}, SrpId, #{id := {PccId, Id}} = Flow) ->
    #{
        is_delegated := IsDelegated,
        is_active := IsActive,
        status := Status,
        route := #{steps := RouteSteps}
    } = Flow,
    %TODO: Add constraints to report
    {ok, #pcep_update{
        srp = #pcep_obj_srp{srp_id = SrpId},
        lsp = #pcep_obj_lsp{
            flag_d = IsDelegated,
            flag_a = IsActive,
            plsp_id = Id,
            status = Status
        },
        ero = route_steps_to_ero(RouteSteps)
    }}.

unpack_compreq(#state{pcc_id = PccId} = State,
               #pcep_compreq{lsp = undefined,
                             rp = #pcep_obj_rp{flag_r = false},
                             rpath = undefined,
                             iro = undefined,
                             load_balancing = undefined
                            } = PcepReq) ->
    % The Request may not contain any LSP ?!? https://datatracker.ietf.org/doc/html/rfc8231#section-5.8.1
    %TODO: check the lsp is not already delegated
    %TODO: Check RP's P flag : https://tools.ietf.org/html/rfc5440#section-7.4
    %TODO: Check Endpoint(s)'s P flag : https://tools.ietf.org/html/rfc5440#section-7.6
    %TODO: Figure out when you could have multiple endpoints....
    {ok, TeReq} = apply_until_error(State, PcepReq, #{owner => PccId}, [
        fun compreq_to_tereq_endpoint/3,
        fun compreq_to_tereq_lspa/3,
        fun compreq_to_tereq_bw/3,
        fun compreq_to_tereq_metrics/3
    ]),
    {request_flow, TeReq, undefined}.

pack_nopath(_State, PcepReq, Reason, _Constraints) ->
    %TODO: add support for NO-PATH-VECTOR TLV
    %TODO: add suport for failing constraints
    #pcep_compreq{rp = RP} = PcepReq,
    NI = case Reason of
        pce_chain_broken -> pce_chain_broken;
        _ -> path_not_found
    end,
    {ok, #pcep_comprep{
        rp = RP#pcep_obj_rp{flag_p = false, flag_i = true},
        nopath = #pcep_obj_nopath{ni = NI}
    }}.

pack_comprep(_State, PcepReq, #{
                steps := Steps,
                constraints := _Constraints
             }) ->
    #pcep_compreq{rp = RP} = PcepReq,
    {ok, #pcep_comprep{
        rp = RP#pcep_obj_rp{flag_p = false, flag_i = true},
        endpoints = [
            #pcep_endpoint{
                paths = [#pcep_path{ero = route_steps_to_ero(Steps)}]
            }
        ]
    }}.

pack_update(#state{cache = Cache}, SrpId, FlowId, Route) ->
    %TODO: Add support for constraints
    case maps:find(FlowId, Cache) of
        error -> {error, flow_not_found};
        {ok, Flow} ->
            %TODO: Check for other changes than the route steps
            #{steps := ReqSteps} = Route,
            #{
                id := {_, PlspId},
                is_delegated := IsDelegated,
                is_active := IsActive,
                status := Status
            } = Flow,
            {ok, #pcep_update{
                srp = #pcep_obj_srp{flag_p = true, srp_id = SrpId},
                lsp = #pcep_obj_lsp{
                    flag_p = true,
                    flag_d = IsDelegated,
                    flag_a = IsActive,
                    plsp_id = PlspId,
                    status = Status
                },
                ero = route_steps_to_ero(ReqSteps),
                bandwidth = undefined,
                metrics = []
            }}
    end.

pack_initiate(#state{pcc_id = PccId}, SrpId, InitRoute) ->
    %TODO: Check there is no flow with the same name
    %TODO: Add support for constraints
    #{source := PccId, destination := Dest, name := Name,
      binding_label := Label, steps := ReqSteps} = InitRoute,
    {ok, #pcep_lsp_init{
        srp = #pcep_obj_srp{
            srp_id = SrpId,
            tlvs = [#pcep_tlv_path_setup_type{pst = srte}]
        },
        lsp = #pcep_obj_lsp{
            flag_a = true,
            tlvs = [
                #pcep_tlv_symbolic_path_name{
                    name = Name
                },
                #pcep_tlv_cisco_binding_label{label = Label}
            ]
        },
        endpoint = pcep_endpoint(PccId, Dest),
        ero = route_steps_to_ero(ReqSteps)
    }}.


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

apply_until_error(_State, _Arg, Acc, []) -> {ok, Acc};
apply_until_error(State, Arg, Acc, [Fun | Rest]) ->
    case Fun(State, Arg, Acc) of
        {error, _Reason} = Error -> Error;
        {ok, NewAcc, NewState} -> apply_until_error(NewState, Arg, NewAcc, Rest)
    end.

map_override(Map, _Ref, []) -> Map;
map_override(Map, Ref, [Key | Rest]) ->
    case maps:find(Key, Map) of
        error ->
            map_override(Map#{Key => maps:get(Key, Ref)}, Ref, Rest);
        {ok, undefined} ->
            map_override(Map#{Key => maps:get(Key, Ref)}, Ref, Rest);
        _ ->
            map_override(Map, Ref, Rest)
    end.

map_changes(Map1, Map2, Keys) ->
    map_changes(Map1, Map2, Keys, []).

map_changes(_Map1, _Map2, [], Acc) ->
    lists:reverse(Acc);
map_changes(Map1, Map2, [Key | Rest], Acc) ->
    case {maps:find(Key, Map1), maps:find(Key, Map2)} of
        {error, error} -> map_changes(Map1, Map2, Rest, Acc);
        {{ok, V}, {ok, V}} -> map_changes(Map1, Map2, Rest, Acc);
        _ -> map_changes(Map1, Map2, Rest, [Key | Acc])
    end.

report_to_flow_lsp(#state{pcc_id = PccId} = State,
                   #pcep_report{lsp = Lsp}, Acc) ->
    % What about the P flag ?
    #pcep_obj_lsp{
        flag_d = IsDelegated,
        flag_a = IsActive,
        plsp_id = Id,
        status = TeStatus,
        tlvs = Tlvs
    } = Lsp,
    {SenderAddr, EndpointAddr} =
        case pcep_server_utils:lookup_tlv(
                [pcep_tlv_ipv4_lsp_id, pcep_tlv_ipv6_lsp_id], Tlvs) of
            error -> {undefined, undefined};
            {ok, #pcep_tlv_ipv4_lsp_id{source = S, endpoint = E}} -> {S, E};
            {ok, #pcep_tlv_ipv6_lsp_id{source = S, endpoint = E}} -> {S, E}
        end,
    Name =
        case pcep_server_utils:lookup_tlv(
                [pcep_tlv_symbolic_path_name], Tlvs) of
            error -> undefined;
            {ok, #pcep_tlv_symbolic_path_name{name = N}} -> N
        end,
    BindingLabel =
        case pcep_server_utils:lookup_tlv(
                [pcep_tlv_cisco_binding_label], Tlvs) of
            error -> undefined;
            {ok, #pcep_tlv_cisco_binding_label{label = L}} -> L
        end,
    Route = maps:get(route, Acc, #{}),
    NewAcc = Acc#{
        id => {PccId, Id},
        is_delegated => IsDelegated,
        is_active => IsActive,
        status => TeStatus,
        name => Name,
        binding_label => BindingLabel,
        route => Route#{
            source => SenderAddr,
            destination => EndpointAddr,
            steps => [],
            constraints => []
        }
    },
    {ok, NewAcc, State}.

report_to_flow_ero(State, #pcep_report{ero = Ero}, Acc) ->
    Route = maps:get(route, Acc, #{}),
    NewAcc = Acc#{route => Route#{steps => xro_to_route_steps(Ero)}},
    {ok, NewAcc, State}.

report_to_flow_lspa(State, #pcep_report{lspa = undefined}, Acc) ->
    {ok, Acc, State};
report_to_flow_lspa(State, #pcep_report{lspa = _Lspa}, Acc) ->
    %TODO: Add LSPA unpacking
    {ok, Acc, State}.

report_to_flow_bw(State, #pcep_report{bandwidth = undefined}, Acc) ->
    {ok, Acc, State};
report_to_flow_bw(State, #pcep_report{bandwidth = _Bandwidth}, Acc) ->
    %TODO: Add bandwidth unpacking
    {ok, Acc, State}.

report_to_flow_metrics(State, #pcep_report{metrics = _Metrics}, Acc) ->
    %TODO: Add metrics unpacking
    {ok, Acc, State}.

compreq_to_tereq_endpoint(State,
        #pcep_compreq{
            rp = #pcep_obj_rp{
                flag_p = true,
                flag_i = false,
                flag_r = false,
                flag_o = CanBeLoose,
                flag_b = Bidi
            },
            endpoints = [
                #pcep_endpoint{endpoint = #pcep_obj_endpoint_ipv4_addr{
                    flag_p = true,
                    flag_i = false,
                    source = Source,
                    destination = Dest
                }}
            ]
        }, Acc) ->
    NewAcc = Acc#{
        source => Source,
        destination => Dest,
        can_be_loose => CanBeLoose,
        bidirectional => Bidi,
        constraints => []
    },
    {ok, NewAcc, State}.

compreq_to_tereq_lspa(State, #pcep_compreq{lspa = undefined}, Acc) ->
    {ok, Acc, State};
compreq_to_tereq_lspa(State, #pcep_compreq{lspa = _Lspa}, Acc) ->
    %TODO: Add LSPA unpacking
    {ok, Acc, State}.

compreq_to_tereq_bw(State, #pcep_compreq{bandwidth = undefined}, Acc) ->
    {ok, Acc, State};
compreq_to_tereq_bw(State, #pcep_compreq{bandwidth = _Bandwidth}, Acc) ->
    %TODO: Add bandwidth unpacking
    {ok, Acc, State}.

compreq_to_tereq_metrics(State, #pcep_compreq{metrics = _Metrics}, Acc) ->
    %TODO: Add metrics unpacking
    {ok, Acc, State}.

xro_to_route_steps(#pcep_obj_ero{path = Objs}) ->
    % What about the P flag ?
    [xro_obj_to_route_steps(O) || O <- Objs].

% We only support SR for now
xro_obj_to_route_steps(#pcep_ro_subobj_sr{} = Obj) ->
    #pcep_ro_subobj_sr{
        flag_l = L,
        has_sid = S,
        has_nai = N,
        nai_type = T,
        sid = Sid,
        nai = Nai
    } = Obj,
    E = #{is_loose => L, nai_type => T},
    E2 = if S -> E#{sid => Sid}; true -> E end,
    E3 = if N -> E2#{nai => Nai}; true -> E2 end,
    E3.

route_steps_to_ero(Steps) ->
    #pcep_obj_ero{path = [route_step_to_xro_obj(S) || S <- Steps]}.

% We only support SR for now
route_step_to_xro_obj(#{is_loose := L, nai_type := T} = Step) ->
    Obj = #pcep_ro_subobj_sr{flag_l = L, nai_type = T},
    Obj2 = route_step_to_xro_obj_sid(Obj, Step),
    Obj3 = route_step_to_xro_obj_nai(Obj2, Step),
    Obj3.

route_step_to_xro_obj_sid(Obj, #{sid := #mpls_stack_entry{} = S}) ->
    Obj#pcep_ro_subobj_sr{has_sid = true, is_mpls = true, sid = S};
route_step_to_xro_obj_sid(Obj, #{sid := #mpls_stack_entry_ext{} = S}) ->
    Obj#pcep_ro_subobj_sr{has_sid = true, is_mpls = true,
                          has_mpls_extra = true, sid = S};
route_step_to_xro_obj_sid(Obj, #{sid := S}) ->
    Obj#pcep_ro_subobj_sr{has_sid = true, sid = S};
route_step_to_xro_obj_sid(Obj, _Step) ->
    Obj.

route_step_to_xro_obj_nai(Obj, #{nai := N}) ->
    Obj#pcep_ro_subobj_sr{has_nai = true, nai = N};
route_step_to_xro_obj_nai(Obj, _Step) ->
    Obj.

check_for_events(Acc, _Ref, _Obj, []) -> Acc;
check_for_events(Acc, Ref, Obj, [Fun | Rest]) ->
    check_for_events(Fun(Ref, Obj, Acc), Ref, Obj, Rest).

% Checks if the status changed between the reference flow and the given LSP
check_for_status_change(#{status := Status},
                        #pcep_obj_lsp{status = Status}, Acc) ->
    Acc;
check_for_status_change(#{status := _OldStatus},
                        #pcep_obj_lsp{status = NewStatus}, Acc) ->
    [{flow_status_changed, NewStatus} | Acc].

% Checks if the route steps changed between the reference flow and the given LSP
check_for_route_change(#{route := #{steps := Steps}},
                       #{route := #{steps := Steps}}, Acc) ->
    Acc;
check_for_route_change(#{route := #{steps := _OldSteps}},
                       #{route := #{steps := NewSteps}}, Acc) ->
    [{flow_route_changed, NewSteps} | Acc].

% Checks if the delegation changed between the reference flow and the given LSP
check_for_delegation(#{status := IsDelegated},
                     #pcep_obj_lsp{flag_d = IsDelegated}, Acc) ->
    Acc;
check_for_delegation(#{is_delegated := false},
                     #pcep_obj_lsp{flag_d = true}, Acc) ->
    [flow_delegated | Acc];
check_for_delegation(#{is_delegated := true},
                     #pcep_obj_lsp{flag_d = false}, Acc) ->
    [flow_revoked | Acc];
check_for_delegation(_Flow, _Lsp, Acc) ->
    Acc.

% Checks if the given LSP is removing the flow
check_for_removal(_Flow, #pcep_obj_lsp{flag_r = true}, Acc) ->
    [flow_removed | Acc];
check_for_removal(_Flow, _Lsp, Acc) ->
    Acc.

pcep_endpoint({_, _, _, _} = S, {_, _, _, _} = D) ->
    #pcep_obj_endpoint_ipv4_addr{flag_i = true, source = S, destination = D};
pcep_endpoint({_, _, _, _, _, _, _, _} = S, {_, _, _, _, _, _, _, _} = D) ->
    #pcep_obj_endpoint_ipv6_addr{flag_i = true, source = S, destination = D}.
