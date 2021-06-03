
%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("pcep_codec/include/pcep_codec_te.hrl").


%%% TYPES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type pcep_session_capability() :: stateful
                                 | lsp_update
                                 | initiated_lsp
                                 | srte_nai_to_sid
                                 | srte_unlimited_msd.

-type init_opts() :: #{
    openwait_timeout => non_neg_integer(),
    keepwait_timeout => non_neg_integer(),
    sync_timeout => non_neg_integer(),
    keepalive_timeout => non_neg_integer(),
    deadtimer_timeout => non_neg_integer(),
    required_capabilities => [pcep_session_capability()]
}.

-type srte_route_step() :: #{
    is_loose := boolean(),
    nai_type := srte_nai_type(),
    nai => srte_nai(),
    sid => srte_sid() | mpls_stack_entry()
}.

-type te_flow_bandwidth_constraint() :: #{
    type := bandwidth,
    is_required := boolean(),
    value := float()
}.

-type te_flow_metric_constraint() :: #{
    type := metric,
    is_required := boolean(),
    is_bound := boolean(),
    % If the metric is requested, the value is optional and vice versa
    is_requested => boolean(),
    value => float()
}.

-type te_flow_affinity_constraint() :: #{
    type := affinity,
    is_required := boolean(),
    exclude_any => non_neg_integer(),
    include_any => non_neg_integer(),
    include_all => non_neg_integer()
}.

-type te_flow_constraint() :: te_flow_bandwidth_constraint()
                           | te_flow_metric_constraint()
                           | te_flow_affinity_constraint().

-type te_route() :: #{
    source := inet:ip_address(),
    destination := inet:ip_address(),
    steps := [srte_route_step()],
    constraints := [te_flow_constraint()]
}.

-type flow_id() :: {inet:ip_address(), non_neg_integer()}.

-type te_flow() :: #{
    id := flow_id(),
    owner := inet:ip_address(),
    is_delegated := boolean(),
    is_active := boolean(),
    status := te_opstatus(),
    name := binary(),
    route := te_route() | undefined
}.

-type te_route_request() :: #{
    owner := inet:ip_address(),
    source := inet:ip_address(),
    destination := inet:ip_address(),
    can_be_loose := boolean(),
    bidirectional := boolean(),
    constraints := [te_flow_constraint()]
}.
