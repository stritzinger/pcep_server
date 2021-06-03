-module(pcep_server_utils).


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% API functions
-export([lookup_tlv/2]).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

lookup_tlv([], _Tlvs) -> error;
lookup_tlv([Name | Rest], Tlvs) ->
    case proplists:lookup(Name, Tlvs) of
        none -> lookup_tlv(Rest, Tlvs);
        Result -> {ok, Result}
    end.
