%%%----------------------------------------------------------------------
%%% File    : mod_caps_store.erl
%%% Author  : Manuel Rubio <bombadil@bosqueviejo.net>
%%% Purpose : Store user capabilities for other modules.
%%% Created : 17 Mar 2013 by Manuel Rubio <bombadil@bosqueviejo.net>
%%%----------------------------------------------------------------------

-module(mod_caps_store).
-author('bombadil@bosqueviejo.net').

-behaviour(gen_server).
-behaviour(gen_mod).

%% gen_mod callbacks
-export([start/2, start_link/2,
	 stop/1, get_caps_by_jid/1, 
	 jid_has/2,
	 get_caps_by_bare_jid/2]).

%% gen_server callbacks
-export([init/1,
	 handle_info/2,
	 handle_call/3,
	 handle_cast/2,
	 terminate/2,
	 code_change/3
	]).

%% hook handlers
-export([user_send_packet/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_mod_caps_store).

-record(caps_store, {jid, node = <<>>, version = <<>>, hash = <<>>, exts=[]}).
-record(state, {host}).

%%====================================================================
%% API
%%====================================================================
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =
	{Proc,
	 {?MODULE, start_link, [Host, Opts]},
	 transient,
	 1000,
	 worker,
	 [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

jid_has(Jid, Feature) when is_binary(Feature) ->
	#caps_store{exts=Exts} = get_caps_by_jid(Jid),
	lists:any(fun(X) -> X =:= Feature end, Exts).

get_caps_by_bare_jid(LUser, LServer) ->
	get_caps_by_jid(#jid{luser=LUser,lserver=LServer}).

get_caps_by_jid(#jid{luser=LUser,lserver=LServer}=Jid) ->
	case mnesia:transaction(fun() ->
		mnesia:read(caps_store, {LUser,LServer})
	end) of
		{atomic, []} ->
			#caps_store{};
		{atomic, [Caps]} when is_record(Caps, caps_store) ->
			Caps;
		Any ->
			?ERROR_MSG("failed to retrieve ~p from caps_store: ~p~n", [Jid, Any]),
			#caps_store{}
	end.

%%====================================================================
%% Hooks
%%====================================================================
user_send_packet(#jid{luser=LUser, lserver=LServer}=From, To, {xmlelement, <<"presence">>, _Attrs, _Els}=Packet) ->
	?INFO_MSG("user_send_packet:~nFrom=~p~nTo=~p~nPacket=~p~n", [From, To, Packet]),
	case xml:get_path_s(Packet, [{elem, <<"c">>}, {attr, <<"ext">>}]) of
		<<>> ->
			?INFO_MSG("presence without capabilities: ~p~n", [Packet]),
			ok;
		Ext ->
			case mnesia:transaction(fun() ->
				mnesia:write(#caps_store{
					jid={LUser,LServer},
					node=xml:get_path_s(Packet, [{elem, <<"c">>}, {attr, <<"node">>}]),
					version=xml:get_path_s(Packet, [{elem, <<"c">>}, {attr, <<"ver">>}]),
					hash=xml:get_path_s(Packet, [{elem, <<"c">>}, {attr, <<"hash">>}]),
					exts=binary:split(Ext, <<" ">>, [global])
				})
			end) of
				{atomic, ok} ->
					ok;
				Any ->
					?ERROR_MSG("Error ~p while store packet: ~p~n", [Any, Packet]),
					ok
			end
	end;
user_send_packet(_From, _To, _Packet) ->
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host, _Opts]) ->
    case catch mnesia:table_info(caps_store, storage_type) of
	{'EXIT', _} ->
	    ok;
	disc_only_copies ->
	    ok;
	_ ->
	    mnesia:delete_table(caps_store)
    end,
    mnesia:create_table(caps_store,
			[{disc_only_copies, [node()]},
			 {attributes, record_info(fields, caps_store)}]),
    mnesia:add_table_copy(caps_store, node(), disc_only_copies),
    ejabberd_hooks:add(user_send_packet, Host,
		       ?MODULE, user_send_packet, 80),
    {ok, #state{host = Host}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    ejabberd_hooks:delete(user_send_packet, Host,
			  ?MODULE, user_send_packet, 80),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Aux functions
%%====================================================================
