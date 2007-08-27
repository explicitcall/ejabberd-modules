%%%----------------------------------------------------------------------
%%% File    : mod_webpresence.erl
%%% Author  : Igor Goryachev <igor@goryachev.org>
%%% Purpose : Allow user to show presence in the web
%%% Created : 30 Apr 2006 by Igor Goryachev <igor@goryachev.org>
%%% Id      : $Id$
%%%----------------------------------------------------------------------

-module(mod_webpresence).
-author('igor@goryachev.org').
-vsn('$Revision$ ').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/2,
         start/2,
         stop/1,
         web_menu_host/2, web_page_host/3,
         process/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_web_admin.hrl").
-include("ejabberd_http.hrl").

-record(webpresence, {us, ridurl = false, jidurl = false, xml = false, avatar = false, icon = "---"}).
-record(state, {host, server_host, base_url, access}).
-record(presence, {resource, show, priority, status}).

%% Copied from ejabberd_sm.erl
-record(session, {sid, usr, us, priority, info}).

-define(PROCNAME, ejabberd_mod_webpresence).

-define(PIXMAPS_DIR, "pixmaps").


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =
	{Proc,
	 {?MODULE, start_link, [Host, Opts]},
	 temporary,
	 1000,
	 worker,
	 [?MODULE]},
    Default_dir = case code:priv_dir(ejabberd) of
		      {error, _} -> ?PIXMAPS_DIR;
		      Path -> filename:join([Path, ?PIXMAPS_DIR])
		  end,
    Dir = gen_mod:get_opt(pixmaps_path, Opts, Default_dir),
    catch ets:new(pixmaps_dirs, [named_table, public]),
    ets:insert(pixmaps_dirs, {directory, Dir}),
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:stop_child(ejabberd_sup, Proc).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Opts]) ->
    mnesia:create_table(webpresence,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, webpresence)}]),
    mnesia:add_table_index(webpresence, ridurl),
    update_table(),
    MyHost = gen_mod:get_opt_host(Host, Opts, "webpresence.@HOST@"),
    Access = gen_mod:get_opt(access, Opts, local),
    Port = gen_mod:get_opt(port, Opts, 5280),
    Path = gen_mod:get_opt(path, Opts, "presence"),
    BaseURL = io_lib:format("http://~s:~p/~s/",[Host, Port, Path]),
    ejabberd_router:register_route(MyHost),
    ejabberd_hooks:add(webadmin_menu_host, Host, ?MODULE, web_menu_host, 50),
    ejabberd_hooks:add(webadmin_page_host, Host, ?MODULE, web_page_host, 50),
    {ok, #state{host = MyHost,
		server_host = Host,
		base_url = BaseURL,
		access = Access}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet},
	    #state{host = Host,
		   server_host = ServerHost,
		   base_url = BaseURL,
		   access = Access} = State) ->
    case catch do_route(Host, ServerHost, Access, From, To, Packet, BaseURL) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]);
	_ ->
	    ok
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, #state{host = Host}) ->
    ejabberd_router:unregister_route(Host),
    ejabberd_hooks:remove(webadmin_menu_host, Host, ?MODULE, web_menu_host, 50),
    ejabberd_hooks:remove(webadmin_page_host, Host, ?MODULE, web_page_host, 50),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

do_route(Host, ServerHost, Access, From, To, Packet, BaseURL) ->
    case acl:match_rule(ServerHost, Access, From) of
	allow ->
	    do_route1(Host, From, To, Packet, BaseURL);
	_ ->
	    {xmlelement, _Name, Attrs, _Els} = Packet,
	    Lang = xml:get_attr_s("xml:lang", Attrs),
	    ErrText = "Access denied by service policy",
	    Err = jlib:make_error_reply(Packet, ?ERRT_FORBIDDEN(Lang, ErrText)),
	    ejabberd_router:route(To, From, Err)
    end.

do_route1(Host, From, To, Packet, BaseURL) ->
    {xmlelement, Name, Attrs, _Els} = Packet,
    case Name of
        "iq" -> do_route1_iq(Host, From, To, Packet, BaseURL, jlib:iq_query_info(Packet));
        _ -> case xml:get_attr_s("type", Attrs) of
		 "error" -> ok;
		 "result" -> ok;
		 _ -> Err = jlib:make_error_reply(Packet, ?ERR_ITEM_NOT_FOUND),
		      ejabberd_router:route(To, From, Err)
	     end
    end.

do_route1_iq(_, From, To, _, _,
	     #iq{type = get, xmlns = ?NS_DISCO_INFO, lang = Lang} = IQ) ->
    SubEl2 = {xmlelement, "query", [{"xmlns", ?NS_DISCO_INFO}], iq_disco_info(Lang)},
    Res = IQ#iq{type = result, sub_el = [SubEl2]},
    ejabberd_router:route(To, From, jlib:iq_to_xml(Res));

do_route1_iq(_, _, _, _, _,
	     #iq{type = get, xmlns = ?NS_DISCO_ITEMS}) ->
    ok;

do_route1_iq(Host, From, To, _, _,
	     #iq{type = get, xmlns = ?NS_REGISTER, lang = Lang} = IQ) ->
    SubEl2 = {xmlelement, "query", [{"xmlns", ?NS_REGISTER}], iq_get_register_info(Host, From, Lang)},
    Res = IQ#iq{type = result, sub_el = [SubEl2]},
    ejabberd_router:route(To, From, jlib:iq_to_xml(Res));

do_route1_iq(Host, From, To, Packet, BaseURL,
	     #iq{type = set, xmlns = ?NS_REGISTER, lang = Lang, sub_el = SubEl} = IQ) ->
    case process_iq_register_set(From, SubEl, Host, BaseURL, Lang) of
	{result, IQRes} ->
	    SubEl2 = {xmlelement, "query", [{"xmlns", ?NS_REGISTER}], IQRes},
	    Res = IQ#iq{type = result, sub_el = [SubEl2]},
	    ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
	{error, Error} ->
	    Err = jlib:make_error_reply(Packet, Error),
	    ejabberd_router:route(To, From, Err)
    end;

do_route1_iq(_Host, From, To, _, _,
	     #iq{type = get, xmlns = ?NS_VCARD = XMLNS} = IQ) ->
    SubEl2 = {xmlelement, "vCard", [{"xmlns", XMLNS}], iq_get_vcard()},
    Res = IQ#iq{type = result, sub_el = [SubEl2]},
    ejabberd_router:route(To, From, jlib:iq_to_xml(Res));

do_route1_iq(_Host, From, To, Packet, _, #iq{}) ->
    Err = jlib:make_error_reply( Packet, ?ERR_FEATURE_NOT_IMPLEMENTED),
    ejabberd_router:route(To, From, Err);

do_route1_iq(_, _, _, _, _, _) ->
    ok.

iq_disco_info(Lang) ->
    [{xmlelement, "identity",
      [{"category", "presence"},
       {"type", "text"},
       {"name", ?T("Web Presence")}], []},
     {xmlelement, "feature", [{"var", ?NS_REGISTER}], []},
     {xmlelement, "feature", [{"var", ?NS_VCARD}], []}].

-define(XFIELDS(Type, Label, Var, Vals),
        {xmlelement, "field", [{"type", Type},
                               {"label", ?T(Label)},
                               {"var", Var}],
         Vals}).

-define(XFIELD(Type, Label, Var, Val),
	?XFIELDS(Type, Label, Var, 
		 [{xmlelement, "value", [], [{xmlcdata, Val}]}])
       ).

%% @spec ridurl_out(ridurl()) -> boolean_string()
%% @type ridurl() = string() | false
%% @type boolean_string() = "true" | "false"
ridurl_out(false) -> "false";
ridurl_out(Id) when is_list(Id) -> "true".

to_bool("false") -> false;
to_bool("true") -> true;
to_bool("0") -> false;
to_bool("1") -> true.

get_pr(LUS) ->
    case catch mnesia:dirty_read(webpresence, LUS) of
	[#webpresence{jidurl = J, ridurl = H, xml = X, avatar = A, icon = I}] ->
	    {J, H, X, A, I, true};
	_ ->
	    {true, false, false, false, "---", false}
    end.

get_pr_rid(LUS) ->
    {_, H, _, _, _, _} = get_pr(LUS),
    H.

iq_get_register_info(_Host, From, Lang) ->
    {LUser, LServer, _} = jlib:jid_tolower(From),
    LUS = {LUser, LServer},
    {JidUrl, RidUrl, XML, Avatar, Icon, Registered} = get_pr(LUS),
    RegisteredXML = case Registered of 
			true -> [{xmlelement, "registered", [], []}];
			false -> []
		    end,
    RegisteredXML ++
	[{xmlelement, "instructions", [],
	  [{xmlcdata, ?T("You need an x:data capable client to register presence")}]},
	 {xmlelement, "x",
	  [{"xmlns", ?NS_XDATA}],
	  [{xmlelement, "title", [],
	    [{xmlcdata,
	      ?T("Web Presence")}]},
	   {xmlelement, "instructions", [], [{xmlcdata, ?T("This form allows you to register in")++" "++?T("Web Presence")++". "++
					      ?T("You will receive a message with usage instructions once registered.")}]},
	   ?XFIELD("fixed", ?T("What types of URL will you use?")++" "++?T("Select one at least"), [], []),
	   ?XFIELD("boolean", "Jabber ID", "jidurl", atom_to_list(JidUrl)),
	   ?XFIELD("boolean", "Random ID", "ridurl", ridurl_out(RidUrl)),
	   ?XFIELD("fixed", ?T("What types of output do you want to allow?")++" "++?T("Select one at least"), [], []),
	   ?XFIELDS("list-single", ?T("Icon theme"), "icon", 
		    [{xmlelement, "value", [], [{xmlcdata, Icon}]},
		     {xmlelement, "option", [{"label", "---"}],
		      [{xmlelement, "value", [], [{xmlcdata, "---"}]}]}             
		    ] ++ available_themes(xdata)
		   ),
	   ?XFIELD("boolean", ?T("Avatar"), "avatar", atom_to_list(Avatar)),
	   ?XFIELD("boolean", ?T("XML"), "xml", atom_to_list(XML))]}].

%% TODO: Check if remote users are allowed to reach here: they should not be allowed
iq_set_register_info(From, {Host, JidUrl, RidUrl, XML, Avatar, Icon, _, Lang} = Opts) ->
    {LUser, LServer, _} = jlib:jid_tolower(From),
    LUS = {LUser, LServer},
    Check_URLTypes = (JidUrl == true) or (RidUrl =/= false),
    Check_OutputTypes = (XML == true) or (Avatar == true) or (Icon =/= "---"),
    case Check_URLTypes and Check_OutputTypes of
	true -> iq_set_register_info2(From, LUS, Opts);
	false -> unregister_webpresence(From, Host, Lang)
    end.

iq_set_register_info2(From, LUS, {Host, JidUrl, RidUrl, XML, Avatar, Icon, BaseURL, Lang}) ->
    RidUrl2 = get_rid_final_value(RidUrl, LUS),
    WP = #webpresence{us = LUS,
		      jidurl = JidUrl,
		      ridurl = RidUrl2,
		      xml = XML,
		      avatar = Avatar,
		      icon = Icon},
    F = fun() -> mnesia:write(WP) end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    send_message_registered(WP, From, Host, BaseURL, Lang),
	    {result, []};
	_ ->
	    {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.

get_rid_final_value(false, _) -> false;
get_rid_final_value(true, {U, S} = LUS) ->
    case get_pr_rid(LUS) of
	false ->
	    integer_to_list(erlang:phash2(U) * erlang:phash2(S) 
			    * calendar:datetime_to_gregorian_seconds(
				calendar:local_time())) 
		++ randoms:get_string();
	H when is_list(H) ->
	    H
    end.

send_message_registered(WP, To, Host, BaseURL, Lang) ->
    {User, Server} = WP#webpresence.us,
    JID = jlib:make_jid(User, Server, ""),
    JIDS = jlib:jid_to_string(JID),
    Oavatar = case WP#webpresence.avatar of
		  false -> "";
		  true -> "  avatar\n"
	      end,
    Oimage = case WP#webpresence.icon of
		 "---" -> "";
		 I when is_list(I) -> 
		     "  image\n"
			 "  image/res/<"++?T("Resource")++">\n"
			 "  image/<"++?T("Icon theme")++">\n"
			 "  image/<"++?T("Icon theme")++">/res/<"++?T("Resource")++">\n"
	     end,
    Oxml = case WP#webpresence.xml of
	       false -> "";
	       true -> "  xml\n"
	   end,
    Allowed_type = case {Oimage, Oxml, Oavatar} of
		       {"", "", _} -> "avatar";
		       {"", _, _} -> "xml";
		       {_, _, _} -> "image"
		   end,
    {USERID_jid, Example_jid} = case WP#webpresence.jidurl of
				    false -> {"", ""};
				    true -> 
					JIDT = "jid/"++User++"/"++Server,
					{"  "++JIDT++"\n",
					 "  "++BaseURL++JIDT++"/"++Allowed_type++"/\n"}
				end,
    {USERID_rid, Example_rid} = case WP#webpresence.ridurl of
				    false -> {"", ""};
				    RID when is_list(RID) -> 
					RIDT = "rid/"++RID,
					{"  "++RIDT++"\n",
					 "  "++BaseURL++RIDT++"/"++Allowed_type++"/\n"}
				end,
    Subject = ?T("Web Presence")++": "++?T("registered"),
    Body = ?T("You have registered")++" "++JIDS++" "++?T("in")++" "++?T("Web Presence")++".\n\n"
	++?T("Use URLs like")++":\n"
	"  "++BaseURL++"USERID/OUTPUT/\n"
	"\n"
	"USERID:\n"++USERID_jid++USERID_rid++"\n"
	"OUTPUT:\n"++Oavatar++Oxml++Oimage++"\n"
	++?T("Example")++":\n"++Example_jid++Example_rid++"\n"
	++?T("If you forget your RandomID, register again to receive this message.")++"\n"
	++?T("To get a new RandomID, disable the option and register again.")++"\n",
    send_headline(Host, To, Subject, Body).

send_message_unregistered(To, Host, Lang) ->
    Subject = ?T("Web Presence")++": "++?T("unregistered"),
    Body = ?T("You have unregistered")++" "++?T("from")++" "++?T("Web Presence")++".\n\n",
    send_headline(Host, To, Subject, Body).

send_headline(Host, To, Subject, Body) ->
    ejabberd_router:route(
      jlib:make_jid("", Host, ""),
      To,
      {xmlelement, "message", [{"type", "headline"}],
       [{xmlelement, "subject", [], [{xmlcdata, Subject}]},
	{xmlelement, "body", [], [{xmlcdata, Body}]}]}).

get_attr(Attr, XData, Default) ->
    case lists:keysearch(Attr, 1, XData) of
	{value, {_, [Value]}} -> Value;
	false -> Default
    end.

process_iq_register_set(From, SubEl, Host, BaseURL, Lang) ->
    {xmlelement, _Name, _Attrs, Els} = SubEl,
    case xml:get_subtag(SubEl, "remove") of
	false -> case catch process_iq_register_set2(From, Els, Host, BaseURL, Lang) of
		     {'EXIT', _} -> {error, ?ERR_BAD_REQUEST};
		     R -> R
		 end;
	_ -> unregister_webpresence(From, Host, Lang)
    end.

process_iq_register_set2(From, Els, Host, BaseURL, Lang) ->
    [{xmlelement, "x", _Attrs1, _Els1} = XEl] = xml:remove_cdata(Els),
    case {xml:get_tag_attr_s("xmlns", XEl), xml:get_tag_attr_s("type", XEl)} of
	{?NS_XDATA, "cancel"} ->
	    {result, []};
	{?NS_XDATA, "submit"} ->
	    XData = jlib:parse_xdata_submit(XEl),
	    invalid =/= XData,
	    JidUrl = get_attr("jidurl", XData, "false"),
	    RidUrl = get_attr("ridurl", XData, "false"),
	    XML = get_attr("xml", XData, "false"),
	    Avatar = get_attr("avatar", XData, "false"),
	    Icon = get_attr("icon", XData, "---"),
	    iq_set_register_info(From, {Host, to_bool(JidUrl), to_bool(RidUrl), to_bool(XML), to_bool(Avatar), Icon, BaseURL, Lang})
    end.

unregister_webpresence(From, Host, Lang) ->
    {LUser, LServer, _} = jlib:jid_tolower(From),
    LUS = {LUser, LServer},
    mnesia:dirty_delete(webpresence, LUS),
    send_message_unregistered(From, Host, Lang),
    {result, []}.

iq_get_vcard() ->
    [{xmlelement, "FN", [],
      [{xmlcdata, "ejabberd/mod_webpresence"}]},
     {xmlelement, "URL", [],
      [{xmlcdata, "http://ejabberd.jabber.ru/mod_webpresence"}]},
     {xmlelement, "DESC", [],
      [{xmlcdata, "ejabberd web presence module\nCopyright (c) 2006-2007 Igor Goryachev"}]}].

get_wp(LUser, LServer) ->
    LUS = {LUser, LServer},
    case catch mnesia:dirty_read(webpresence, LUS) of
        {'EXIT', _Reason} -> 
	    #webpresence{};
        [] -> 
	    #webpresence{};
	[WP] when is_record(WP, webpresence) ->
	    WP
    end.

get_status_weight(Show) ->
    case Show of
        "chat"      -> 0;
        "available" -> 1;
        "away"      -> 2;
        "xa"        -> 3;
        "dnd"       -> 4;
        _           -> 9
    end.


get_presences({bare, LUser, LServer}) ->
    Resources = ejabberd_sm:get_user_resources(LUser, LServer),
    lists:map(
      fun(Resource) ->
              [Session] = mnesia:dirty_index_read(session,
                                                  {LUser, LServer, Resource},
                                                  #session.usr),
              Pid = element(2, Session#session.sid),
              {_User, _Resource, Show, Status} =
                  rpc:call(node(Pid), ejabberd_c2s, get_presence, [Pid]),
              Priority = Session#session.priority,
              #presence{resource = Resource,
                        show = Show,
                        priority = Priority,
                        status = Status}
      end,
      Resources);
get_presences({sorted, LUser, LServer}) ->
    lists:sort(
      fun(A, B) ->
              if
                  A#presence.priority == B#presence.priority ->
                      WA = get_status_weight(A#presence.show),
                      WB = get_status_weight(B#presence.show),
                      WA < WB;
                  true ->
                      A#presence.priority > B#presence.priority
              end
      end,
      get_presences({bare, LUser, LServer}));
get_presences({xml, LUser, LServer, Show_us}) ->
    {xmlelement, "presence",
     case Show_us of 
	 true -> [{"user", LUser}, {"server", LServer}];
	 false -> []
     end,
     lists:map(
       fun(Presence) ->
               {xmlelement, "resource",
                [{"name", Presence#presence.resource},
                 {"show", Presence#presence.show},
                 {"priority", integer_to_list(Presence#presence.priority)}],
                [{xmlcdata, Presence#presence.status}]}
       end,
       get_presences({sorted, LUser, LServer}))};
get_presences({show, LUser, LServer, LResource}) ->
    Rs = get_presences({sorted, LUser, LServer}),
    {value, R} = lists:keysearch(LResource, 2, Rs),
    R#presence.show;
get_presences({show, LUser, LServer}) ->
    case get_presences({sorted, LUser, LServer}) of
        [Highest | _Rest] ->
            Highest#presence.show;
        _ ->
            "unavailable"
    end.

-define(XML_HEADER, "<?xml version='1.0' encoding='utf-8'?>").

get_pixmaps_directory() ->
    [{directory, Path} | _] = ets:lookup(pixmaps_dirs, directory),
    Path.

available_themes(list) ->
    case file:list_dir(get_pixmaps_directory()) of
        {ok, List} ->
            L2 = lists:sort(List),
	    %% Remove from the list of themes the directories that start with a dot
	    [T || T <- L2, hd(T) =/= 46];
        {error, _} ->
            []
    end;
available_themes(xdata) ->
    lists:map(
      fun(Theme) ->
              {xmlelement, "option", [{"label", Theme}],
               [{xmlelement, "value", [], [{xmlcdata, Theme}]}]}
      end, available_themes(list)).

show_presence({image_no_check, Theme, Pr}) ->
    Dir = get_pixmaps_directory(),
    Image = Pr ++ ".{gif,png,jpg}",
    [First | _Rest] = filelib:wildcard(filename:join([Dir, Theme, Image])),
    Mime = string:substr(First, string:len(First) - 2, 3),
    {ok, Content} = file:read_file(First),
    {200, [{"Content-Type", "image/" ++ Mime}], binary_to_list(Content)};

show_presence({image, WP, LUser, LServer}) ->
    Icon = WP#webpresence.icon,
    "---" =/= Icon,
    Pr = get_presences({show, LUser, LServer}),
    show_presence({image_no_check, Icon, Pr});

show_presence({image, WP, LUser, LServer, Theme}) ->
    "---" =/= WP#webpresence.icon,
    Pr = get_presences({show, LUser, LServer}),
    show_presence({image_no_check, Theme, Pr});

show_presence({image_res, WP, LUser, LServer, LResource}) ->
    Icon = WP#webpresence.icon,
    "---" =/= Icon,
    Pr = get_presences({show, LUser, LServer, LResource}),
    show_presence({image_no_check, Icon, Pr});

show_presence({image_res, WP, LUser, LServer, Theme, LResource}) ->
    "---" =/= WP#webpresence.icon,
    Pr = get_presences({show, LUser, LServer, LResource}),
    show_presence({image_no_check, Theme, Pr});

show_presence({xml, WP, LUser, LServer, Show_us}) ->
    true = WP#webpresence.xml,
    Presence_xml = xml:element_to_string(get_presences({xml, LUser, LServer, Show_us})),
    {200, [{"Content-Type", "text/xml; charset=utf-8"}], ?XML_HEADER ++ Presence_xml};

show_presence({avatar, WP, LUser, LServer}) ->
    true = WP#webpresence.avatar,
    [{_, Module, Function, _Opts}] = ets:lookup(sm_iqtable, {?NS_VCARD, LServer}),
    JID = jlib:make_jid(LUser, LServer, ""),
    IQ = #iq{type = get, xmlns = ?NS_VCARD},
    IQr = Module:Function(JID, JID, IQ),
    [VCard] = IQr#iq.sub_el,
    Mime = xml:get_path_s(VCard, [{elem, "PHOTO"}, {elem, "TYPE"}, cdata]),
    BinVal = xml:get_path_s(VCard, [{elem, "PHOTO"}, {elem, "BINVAL"}, cdata]),
    Photo = jlib:decode_base64(BinVal),
    {200, [{"Content-Type", Mime}], Photo};

show_presence({image_example, Theme, Show}) ->
    Dir = get_pixmaps_directory(),
    Image = Show ++ ".{gif,png,jpg}",
    [First | _Rest] = filelib:wildcard(filename:join([Dir, Theme, Image])),
    Mime = string:substr(First, string:len(First) - 2, 3),
    {ok, Content} = file:read_file(First),
    {200, [{"Content-Type", "image/" ++ Mime}], binary_to_list(Content)}.


%% ---------------------
%% Web Publish
%% ---------------------

make_xhtml(Els) -> make_xhtml([], Els).
make_xhtml(Title, Els) ->
    {xmlelement, "html", [{"xmlns", "http://www.w3.org/1999/xhtml"},
			  {"xml:lang", "en"},
			  {"lang", "en"}],
     [{xmlelement, "head", [],
       [{xmlelement, "meta", [{"http-equiv", "Content-Type"},
			      {"content", "text/html; charset=utf-8"}], []}]
       ++ Title},
      {xmlelement, "body", [], Els}
     ]}.

themes_to_xhtml(Themes) ->
    ShowL = ["chat", "available", "away", "xa", "dnd"],
    THeadL = [""] ++ ShowL,
    [?XAE("table", [], 
	  [?XE("tr", [?XC("th", T) || T <- THeadL])] ++
	  [?XE("tr", [?XC("td", Theme) |
		      [?XE("td", [?XA("img", [{"src", "image/"++Theme++"/"++T}])]) || T <- ShowL]
		     ]
	      ) || Theme <- Themes]
	 )
    ].

parse_lang(Lang) -> hd(string:tokens(Lang,"-")).

process(LocalPath, Request) ->
    case catch process2(LocalPath, Request) of
	{'EXIT', _Reason} ->
	    {404, [], make_xhtml([?XC("h1", "Not found")])};
	Res ->
	    Res
    end.

process2([], #request{lang = Lang1}) ->
    Lang = parse_lang(Lang1),
    Title = [?XC("title", ?T("Web Presence"))],
    Desc = [?XC("p", ?T("To publish your presence in this web you need a Jabber account in this Jabber server.")++" "++
		?T("Login with a Jabber client, open")++" "++?T("Service Discovery")++" "++?T("and register in")++" "++?T("Web Presence")++". "++
		?T("You will receive a message with further instructions."))],
    Link_themes = [?AC("themes", ?T("Icon Theme"))],
    Body = [?XC("h1", ?T("Web Presence"))] ++ Desc ++ Link_themes,
    make_xhtml(Title, Body);

process2(["themes"], #request{lang = Lang1}) ->
    Lang = parse_lang(Lang1),
    Title = [?XC("title", ?T("Web Presence")++" - "++?T("Icon Theme"))],
    Themes = available_themes(list),
    Icon_themes = themes_to_xhtml(Themes),
    Body = [?XC("h1", ?T("Icon Theme"))] ++ Icon_themes,
    make_xhtml(Title, Body);

process2(["image", Theme, Show], _Request) ->
    Args = {image_example, Theme, Show},
    show_presence(Args);

process2(["jid", User, Server | Tail], _Request) ->
    serve_web_presence(jid, User, Server, Tail);

process2(["rid", Rid | Tail], _Request) ->
    [Pr] = mnesia:dirty_index_read(webpresence, Rid, #webpresence.ridurl),
    {User, Server} = Pr#webpresence.us,
    serve_web_presence(rid, User, Server, Tail);

%% Compatibility with old mod_presence
process2([User, Server | Tail], _Request) ->
    serve_web_presence(jid, User, Server, Tail).


serve_web_presence(TypeURL, User, Server, Tail) ->
    LServer = jlib:nameprep(Server),
    true = lists:member(LServer, ?MYHOSTS),
    LUser = jlib:nodeprep(User),
    WP = get_wp(LUser, LServer),
    case TypeURL of
	jid -> true =:= WP#webpresence.jidurl;
	rid -> false =/= WP#webpresence.ridurl
    end,
    Args = case Tail of
	       ["image"] -> 
		   {image, WP, LUser, LServer};
	       ["image", Theme] -> 
		   {image, WP, LUser, LServer, Theme};
	       ["image", "res", Resource] -> 
		   {image_res, WP, LUser, LServer, Resource};
	       ["image", Theme, "res", Resource] -> 
		   {image_res, WP, LUser, LServer, Theme, Resource};
	       ["xml"] -> 
		   Show_us = (TypeURL == jid),
		   {xml, WP, LUser, LServer, Show_us};
	       ["avatar"] -> 
		   {avatar, WP, LUser, LServer}
	   end,
    show_presence(Args).


%% ---------------------
%% Web Admin
%% ---------------------

web_menu_host(Acc, _Host) ->
    [{"webpresence", "Web Presence"} | Acc].

web_page_host(_, _Host, 
	      #request{path = ["webpresence"],
		       lang = Lang} = _Request) ->
    Res = [?XCT("h1", "Web Presence"),
	   ?ACT("users", "Registered Users")],
    {stop, Res};

web_page_host(_, Host, 
	      #request{path = ["webpresence", "users"],
		       lang = Lang} = _Request) ->
    Users = get_users(Host),
    Table = make_users_table(Users, Lang),
    Res = [?XCT("h1", "Web Presence"),
	   ?XCT("h2", "Registered Users")] ++ Table,
    {stop, Res};

web_page_host(Acc, _, _) -> Acc. 

get_users(Host) ->
    Select = [{{webpresence, {'$1', Host}, '$2', '$3', '$4', '$5', '$6'}, [], ['$$']}],
    mnesia:dirty_select(webpresence, Select).

make_users_table(Records, Lang) ->
    TList = lists:map(
	      fun([User, RidUrl, JIDUrl, XML, Avatar, Icon]) ->
		      ?XE("tr",
			  [?XE("td", [?AC("../user/"++User++"/", User)]),
			   ?XC("td", atom_to_list(JIDUrl)),
			   ?XC("td", ridurl_out(RidUrl)),
			   ?XC("td", atom_to_list(XML)),
			   ?XC("td", atom_to_list(Avatar)),
			   ?XC("td", Icon)])
	      end, Records),
    [?XE("table",
	 [?XE("thead",
	      [?XE("tr",
		   [?XCT("td", "User"),
		    ?XCT("td", "Jabber ID"),
		    ?XCT("td", "Random ID"),
		    ?XCT("td", "XML"),
		    ?XCT("td", "Avatar"),
		    ?XCT("td", "Icon theme")
		   ])]),
	  ?XE("tbody", TList)])].


%%%--------------------------------
%%% Update table schema and content from older versions
%%%--------------------------------

update_table() ->
    case catch mnesia:table_info(presence_registered, size) of
	Size when is_integer(Size) -> catch migrate_data_mod_presence(Size);
	_ -> ok
    end.

migrate_data_mod_presence(Size) ->
    Migrate = fun(Old, S) ->
		      {presence_registered, {US, _Host}, XML, Icon} = Old,
		      New = #webpresence{us = US,
					 ridurl = false,
					 jidurl = true,
					 xml = list_to_atom(XML),
					 avatar = false,
					 icon = Icon},
		      mnesia:write(New),
		      mnesia:delete_object(Old),
		      S-1
	      end,
    F = fun() -> mnesia:foldl(Migrate, Size, presence_registered) end,
    {atomic, 0} = mnesia:transaction(F),
    {atomic, ok} = mnesia:delete_table(presence_registered).