%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
%%

-module(rabbit_auth_backend_ip_range).

-behaviour(rabbit_auth_backend).

-include_lib("rabbit_common/include/rabbit.hrl").

-export([description/0]).
-export([check_user_login/2, check_vhost_access/3, check_resource_access/3]).

description() ->
    [{name, <<"IP_Range">>},
     {description, <<"LDAP authentication / authorisation">>}].

check_user_login(Username, _) ->
    {ok, #auth_user{username = Username,
                    tags     = [],
                    impl     = none}}.

check_vhost_access(#auth_user{tags = Tags}, _VHostPath, Sock) ->
    Address = extract_address(Sock),

    % filter out applicable masks
    case lists:filtermap(
            fun({Tag, Masks}) ->
                case lists:member(Tag, Tags) of
                    true -> {true, Masks};
                    false -> false
                end
            end, env(tag_masks)) of
        []   -> check_masks(Address, env(default_masks));
        Else -> check_masks(Address, lists:flatten(Else))
    end.

check_masks(undefined, _Masks) -> true; % allow internal access
check_masks(Address, Masks) ->
    R = lists:foldl(
        fun(StrMask, false) ->
            {Mask, Bits} = compile_addrmask(StrMask),
            Addr = address_to_binary(Address, Bits),
            if
                Addr == Mask -> true;
                true         -> false
            end;
	   (_, true) -> true
        end, false, Masks),
    if
        R == false ->
            rabbit_log:info("Address ~w not matching any of ~w~n", [Address, Masks]),
            false;
        true -> true
    end.

check_resource_access(#auth_user{}, #resource{}, _Permission) -> true.

%%--------------------------------------------------------------------

env(F) ->
    {ok, V} = application:get_env(rabbitmq_auth_backend_ip_range, F),
    V.

extract_address(undefined) -> undefined;
extract_address(Sock) ->
    {ok, {Address, _Port}} = rabbit_net:sockname(Sock),
    Address.

compile_addrmask(AddrMask) ->
    case string:tokens(binary_to_list(AddrMask), "/\\") of
        [Addr] ->
            {ABin, ABits} = compile_address(Addr);
        [Addr, Bits] ->
            {ABin, _} = compile_address(Addr),
            ABits = list_to_integer(Bits)
    end,
    {address_to_binary(ABin, ABits), ABits}.

compile_address(Addr) ->
    case inet:parse_address(Addr) of
        {ok, Address4} when size(Address4) == 4 -> {Address4, 32};
        {ok, Address6} when size(Address6) == 8 -> {Address6, 128};
        {error, _} -> throw({error, einval})
    end.

address_to_binary({B1, B2, B3, B4}, Bits) when Bits >= 32->
    <<B1:8, B2:8, B3:8, B4:8>>;

address_to_binary({B1, B2, B3, B4}, Bits) ->
    <<Subset:Bits/bitstring, _Others/bitstring>> = <<B1:8, B2:8, B3:8, B4:8>>,
    Subset;

address_to_binary({W1, W2, W3, W4, W5, W6, W7, W8}, Bits) ->
    <<Subset:Bits/bitstring, _Others/bitstring>> = <<W1:16, W2:16, W3:16, W4:16, W5:16, W6:16, W7:16, W8:16>>,
    Subset;

address_to_binary(_, 0) -> <<0>>.

%% end of file
