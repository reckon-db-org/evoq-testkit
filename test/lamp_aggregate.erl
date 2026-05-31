%%% @doc Test-support aggregate: a lamp, as a real evoq_aggregate.
%%%
%%% A proper module (exported callbacks) so it works for BOTH layers:
%%% the pure Layer-A spec (init/1 + execute/2 + apply/2) and the Layer-B
%%% integration tests, where the aggregate runtime starts it as a gen_server
%%% and drives it through the real dispatch path.
%%%
%%% off -> on -> off; illegal transitions are rejected. State = #{on => bool}.
-module(lamp_aggregate).
-behaviour(evoq_aggregate).

-export([state_module/0, init/1, execute/2, apply/2]).
-export([stream_id/1, is_on/1]).

state_module() -> ?MODULE.

init(_StreamId) -> {ok, #{on => false}}.

execute(#{on := false}, #{command_type := <<"turn_on">>}) ->
    {ok, [#{event_type => <<"lamp_turned_on">>}]};
execute(#{on := true}, #{command_type := <<"turn_on">>}) ->
    {error, already_on};
execute(#{on := true}, #{command_type := <<"turn_off">>}) ->
    {ok, [#{event_type => <<"lamp_turned_off">>}]};
execute(#{on := false}, #{command_type := <<"turn_off">>}) ->
    {error, already_off};
execute(_State, #{command_type := Other}) ->
    {error, {unknown_command, Other}}.

apply(State, #{event_type := <<"lamp_turned_on">>})  -> State#{on => true};
apply(State, #{event_type := <<"lamp_turned_off">>}) -> State#{on => false};
apply(State, _)                                       -> State.

%% A reckon-db-compliant stream id derived from a human name:
%% `lamp-<md5 hex>' = `[a-z]{1,32}-[a-f0-9]{32}'.
-spec stream_id(binary()) -> binary().
stream_id(Name) when is_binary(Name) ->
    Hex = binary:encode_hex(crypto:hash(md5, Name), lowercase),
    <<"lamp-", Hex/binary>>.

is_on(#{on := V}) -> V.
