%%%-------------------------------------------------------------------
%%% @author ludwikbukowski
%%% @copyright (C) 2018, Erlang-Solutions
%%% @doc
%%%
%%% @end
%%% Created : 30. Jan 2018 13:22
%%%-------------------------------------------------------------------
-module(mod_inbox_muclight).
-author("ludwikbukowski").
-include("mod_muc_light.hrl").
-include("mod_inbox.hrl").
-include("jlib.hrl").
-include("mongoose_ns.hrl").
-include("mongoose.hrl").

-export([handle_outgoing_message/5, handle_incoming_message/5]).

-type packet() :: exml:element().
-type role() :: r_member() | r_owner() | r_none().
-type r_member() :: binary().
-type r_owner() :: binary().
-type r_none() :: binary().

-spec handle_outgoing_message(Host :: jid:server(),
                              User :: jid:jid(),
                              Room :: jid:jid(),
                              Packet :: packet(),
                              TS :: integer()) -> any().
handle_outgoing_message(Host, User, Room, Packet, _TS) ->
    maybe_reset_unread_count(Host, User, Room, Packet).

-spec handle_incoming_message(Host :: jid:server(),
                              RoomUser :: jid:jid(),
                              Remote :: jid:jid(),
                              Packet :: packet(),
                              TS :: integer()) -> any().
handle_incoming_message(Host, RoomUser, Remote, Packet, TS) ->
    case mod_inbox_utils:has_chat_marker(Packet) of
        true ->
            %% don't store chat markers in inbox
            ok;
        false ->
            maybe_handle_system_message(Host, RoomUser, Remote, Packet, TS)
    end.

maybe_reset_unread_count(Host, User, Room, Packet) ->
    mod_inbox_utils:maybe_reset_unread_count(Host, User, Room, Packet).

-spec maybe_handle_system_message(Host :: host(),
                                  RoomOrUser :: jid:jid(),
                                  Receiver :: jid:jid(),
                                  Packet :: exml:element(),
                                  TS :: integer()) -> ok.
maybe_handle_system_message(Host, RoomOrUser, Receiver, Packet, TS) ->
    case is_system_message(RoomOrUser, Receiver, Packet) of
        true ->
            handle_system_message(Host, RoomOrUser, Receiver, Packet, TS);
        _ ->
            Sender = jid:from_binary(RoomOrUser#jid.lresource),
            write_to_inbox(Host, RoomOrUser, Receiver, Sender, Packet, TS)
    end.

-spec handle_system_message(Host :: host(),
                            Room :: jid:jid(),
                            Remote :: jid:jid(),
                            Packet :: exml:element(),
                            TS :: integer()) -> ok.
handle_system_message(Host, Room, Remote, Packet, TS) ->
    case system_message_type(Remote, Packet) of
        kick ->
            handle_kicked_message(Host, Room, Remote, Packet, TS);
        invite ->
            handle_invitation_message(Host, Room, Remote, Packet, TS);
        other ->
            ?LOG_DEBUG(#{what => irrelevant_system_message_for_mod_inbox_muclight,
                         room => Room, exml_packet => Packet}),
            ok
    end.

-spec handle_invitation_message(Host :: host(),
                                Room :: jid:jid(),
                                Remote :: jid:jid(),
                                Packet :: exml:element(),
                                TS :: integer()) -> ok.
handle_invitation_message(Host, Room, Remote, Packet, TS) ->
    maybe_store_system_message(Host, Room, Remote, Packet, TS).

-spec handle_kicked_message(Host :: host(),
                            Room :: jid:jid(),
                            Remote :: jid:jid(),
                            Packet :: exml:element(),
                            TS :: integer()) -> ok.
handle_kicked_message(Host, Room, Remote, Packet, TS) ->
    CheckRemove = mod_inbox_utils:get_option_remove_on_kicked(Host),
    maybe_store_system_message(Host, Room, Remote, Packet, TS),
    maybe_remove_inbox_row(Host, Room, Remote, CheckRemove).

-spec maybe_store_system_message(Host :: host(),
                                 Room :: jid:jid(),
                                 Remote :: jid:jid(),
                                 Packet :: exml:element(),
                                 TS :: integer()) -> ok.
maybe_store_system_message(Host, Room, Remote, Packet, TS) ->
    WriteAffChanges = mod_inbox_utils:get_option_write_aff_changes(Host),
    case WriteAffChanges of
        true ->
            write_to_inbox(Host, Room, Remote, Room, Packet, TS);
        false ->
            ok
    end.

-spec maybe_remove_inbox_row(Host :: host(),
                             Room :: jid:jid(),
                             Remote :: jid:jid(),
                             WriteAffChanges :: boolean()) -> ok.
maybe_remove_inbox_row(_, _, _, false) ->
    ok;
maybe_remove_inbox_row(Host, Room, Remote, true) ->
    UserBin = Remote#jid.luser,
    RoomBin = jid:to_binary(Room),
    ok = mod_inbox_backend:remove_inbox_row(UserBin, Host, RoomBin).

-spec write_to_inbox(Server :: host(),
                     RoomUser :: jid:jid(),
                     Remote :: jid:jid(),
                     Sender :: jid:jid(),
                     Packet :: exml:element(),
                     TS :: integer()) -> ok.
write_to_inbox(Server, RoomUser, Remote, Remote, Packet, TS) ->
    mod_inbox_utils:write_to_sender_inbox(Server, Remote, RoomUser, Packet, TS);
write_to_inbox(Server, RoomUser, Remote, _Sender, Packet, TS) ->
    mod_inbox_utils:write_to_receiver_inbox(Server, RoomUser, Remote, Packet, TS).

%%%%%%%
%% Predicate funs

%% @doc Check if sender is just 'roomname@muclight.domain' with no resource
%% TODO: Replace sender domain check with namespace check - current logic won't handle all cases!
-spec  is_system_message(Sender :: jid:jid(),
                         Receiver :: jid:jid(),
                         Packet :: exml:element()) -> boolean().
is_system_message(Sender, Receiver, Packet) ->
    ReceiverDomain = Receiver#jid.lserver,
    MUCLightDomain = gen_mod:get_module_opt_subhost(ReceiverDomain, mod_muc_light,
                                                    mod_muc_light:default_host()),
    case {Sender#jid.lserver, Sender#jid.lresource} of
        {MUCLightDomain, <<>>} ->
            true;
        {MUCLightDomain, _RoomUser} ->
            false;
        _Other ->
            ?LOG_WARNING(#{what => inbox_muclight_unknown_message, packet => Packet,
                           sender => jid:to_binary(Sender), receiver => jid:to_binary(Receiver)})
    end.


-spec is_change_aff_message(jid:jid(), exml:element(), role()) -> boolean().
is_change_aff_message(User, Packet, Role) ->
    AffItems = exml_query:paths(Packet, [{element_with_ns, ?NS_MUC_LIGHT_AFFILIATIONS},
        {element, <<"user">>}]),
    AffList = get_users_with_affiliation(AffItems, Role),
    Jids = [Jid || #xmlel{children = [#xmlcdata{content = Jid}]} <- AffList],
    UserBin = jid:to_binary(jid:to_lower(jid:to_bare(User))),
    lists:member(UserBin, Jids).

-spec system_message_type(User :: jid:jid(), Packet :: exml:element()) -> invite | kick | other.
system_message_type(User, Packet) ->
    IsInviteMsg = is_invitation_message(User, Packet),
    IsNewOwnerMsg = is_new_owner_message(User, Packet),
    IsKickedMsg = is_kicked_message(User, Packet),
    if IsInviteMsg orelse IsNewOwnerMsg ->
        invite;
       IsKickedMsg ->
            kick;
       true ->
            other
            end.

-spec is_invitation_message(jid:jid(), exml:element()) -> boolean().
is_invitation_message(User, Packet) ->
    is_change_aff_message(User, Packet, <<"member">>).

-spec is_new_owner_message(jid:jid(), exml:element()) -> boolean().
is_new_owner_message(User, Packet) ->
    is_change_aff_message(User, Packet, <<"owner">>).

-spec is_kicked_message(jid:jid(), exml:element()) -> boolean().
is_kicked_message(User, Packet) ->
    is_change_aff_message(User, Packet, <<"none">>).

-spec get_users_with_affiliation(list(exml:element()), role()) -> list(exml:element()).
get_users_with_affiliation(AffItems, Role) ->
    [M || #xmlel{name = <<"user">>, attrs = [{<<"affiliation">>, R}]} = M <- AffItems, R == Role].
