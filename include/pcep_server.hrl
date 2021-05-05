
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
