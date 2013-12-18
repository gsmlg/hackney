%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% @doc HTTP parser in pure Erlang

-module(hackney_http).

-export([parser/0, parser/1]).

-record(hparser, {type=auto,
                  max_line_length=4096,
                  max_empty_lines=10,
                  empty_lines=0,
                  state=on_first_line,
                  buffer = <<>>,
                  version,
                  method,
                  partial_headers=[],
                  clen,
                  te,
                  connection,
                  ctype,
                  location,
                  body_state=waiting}).

parser() ->
    parser([]).

parser(Options) ->
    InitState = parse_options(Options, #hparser{}),
    fun(Bin) -> incomplete_handler(Bin, InitState) end.


incomplete_handler(Bin, #hparser{buffer=Buffer}=St) ->
    NBuffer = << Buffer/binary, Bin/binary >>,
    execute(St#hparser{buffer=NBuffer}).

execute(#hparser{state=Status, buffer=Buffer}=St) ->
    case Status of
        done -> done;
        on_first_line -> parse_first_line(Buffer, St, 0);
        on_header -> parse_headers(St);
        on_body -> parse_body(St)
    end.

%% Empty lines must be using \r\n.
parse_first_line(<< $\n, _/binary >>, _St, _) ->
    {error, badarg};
%% We limit the length of the first-line to MaxLength to avoid endlessly
%% reading from the socket and eventually crashing.
parse_first_line(Buffer, St=#hparser{type=Type,
                                     max_line_length=MaxLength,
                                     max_empty_lines=MaxEmpty}, Empty) ->
    case match_eol(Buffer, 0) of
        nomatch when byte_size(Buffer) > MaxLength ->
            {error, line_too_long};
        nomatch ->
            {more, fun(Bin) ->
                        incomplete_handler(Bin, St#hparser{empty_lines=Empty})
                end};
        1 when Empty =:= MaxEmpty ->
            {error, bad_request};
        1 ->
            << _:16, Rest/binary >> = Buffer,
            parse_first_line(Rest, St, Empty + 1);
        _ when Type =:= auto ->
            case parse_request_line(St) of
                {error, bad_request} ->
                    case parse_response_line(St) of
                        {error, bad_request} = Error ->
                            Error;
                        OK ->
                            OK
                    end;
                OK ->
                    OK
            end;
        _ when Type =:= response ->
            parse_response_line(Buffer, St);
        _ when Type =:= request ->
            parse_request_line(St)
    end.

match_eol(<< $\n, _/bits >>, N) ->
    N;
match_eol(<< _, Rest/bits >>, N) ->
    match_eol(Rest, N + 1);
match_eol(_, _) ->
    nomatch.

%% @doc parse status
parse_response_line(#hparser{buffer=Buf}=St) ->
    case binary:split(Buf, <<"\r\n">>) of
        [Line, Rest] ->
            parse_response_line(Line, St#hparser{buffer=Rest});
        _ ->
            {error, bad_request}
    end.


parse_response_line(<< "HTTP/", High, ".", Low, " ", Status/binary >>, St)
        when High >= $0, High =< $9, Low >= $0, Low =< $9 ->

    Version = { High -$0, Low - $0},
    [StatusCode, Reason] = binary:split(Status, <<" ">>, [trim]),
    StatusInt = list_to_integer(binary_to_list(StatusCode)),

    NState = St#hparser{type=response,
                        version=Version,
                        state=on_header,
                        partial_headers=[]},

    {response, StatusInt, Reason, fun() -> execute(NState) end}.

parse_request_line(#hparser{buffer=Buf}=St) ->
    parse_method(Buf, St, <<>>).


parse_method(<< C, Rest/bits >>, St, Acc) ->
    case C of
        $\r ->  {error, bad_request};
        $\s -> parse_uri(Rest, St, Acc);
        _ -> parse_method(Rest, St, << Acc/binary, C >>)
    end.

parse_uri(<< $\r, _/bits >>, _St, _) ->
    {error, bad_request};
parse_uri(<< "* ", Rest/bits >>, St, Method) ->
    parse_version(Rest, St, Method, <<"*">>);
parse_uri(Buffer, St, Method) ->
    parse_uri_path(Buffer, St, Method, <<>>).


parse_uri_path(<< C, Rest/bits >>, St, Method, Acc) ->
    case C of
        $\r -> {error, bad_request};
        $\s -> parse_version(Rest, St, Method, Acc);
        _ -> parse_uri_path(Rest, St, Method, << Acc/binary, C >>)
    end.

parse_version(<< "HTTP/", High, ".", Low, Rest/binary >>, St, Method, URI)
        when High >= $0, High =< $9, Low >= $0, Low =< $9 ->
    Version = { High -$0, Low - $0},

    NState = St#hparser{type=request,
                        version=Version,
                        method=Method,
                        state=on_header,
                        buffer=Rest,
                        partial_headers=[]},
    {request, Method, URI, fun() -> execute(NState) end};
parse_version(_, _, _, _) ->
     {error, bad_request}.


%% @doc fetch all headers
parse_headers(#hparser{partial_headers=Headers}=St) ->
    case parse_header(St) of
        {more, St2} ->
            {more, fun(Bin) -> incomplete_handler(Bin, St2) end};
        {headers_complete, St2} ->
            {headers_complete, fun() -> execute(St2) end};
        {header, KV, St2} ->
            {header, KV, fun() -> execute(St2) end};
        {error, Reason, Acc} ->
            {error, {Reason, {Acc, Headers}}}
    end.


parse_header(#hparser{buffer=Buf}=St) ->
    case binary:split(Buf, <<"\r\n">>) of
        [<<>>, Rest] ->
            {headers_complete, St#hparser{buffer=Rest,
                                          state=on_body}};
        [<< " ", Line/binary >>, Rest] ->
            NewBuf = iolist_to_binary([Line, Rest]),
            parse_header(St#hparser{buffer=NewBuf});
        [<< "\t", Line/binary >>, Rest] ->
            NewBuf = iolist_to_binary([Line, Rest]),
            parse_header(St#hparser{buffer=NewBuf});
        [Line, Rest]->
            parse_header(Line, St#hparser{buffer=Rest});
        [Buf] ->
            {more, St}
    end.


parse_header(Line, St) ->
    [Key, Value] = case binary:split(Line, <<": ">>, [trim]) of
        [K] -> [K, <<>>];
        [K, V] -> [K, V]
    end,
    St1 = case hackney_util:to_lower(Key) of
        <<"content-length">> ->
            CLen = list_to_integer(binary_to_list(Value)),
            St#hparser{clen=CLen};
        <<"transfer-encoding">> ->
            St#hparser{te=hackney_util:to_lower(Value)};
        <<"connection">> ->
            St#hparser{connection=hackney_util:to_lower(Value)};
        <<"content-type">> ->
            St#hparser{ctype=hackney_util:to_lower(Value)};
        <<"location">> ->
            St#hparser{location=Value};
        _ ->
           St
    end,
    {header, {Key, Value}, St1}.


parse_body(St=#hparser{body_state=waiting, te=TE, clen=Length,
                           method=Method}) ->
	case TE of
		<<"chunked">> ->
			parse_body(St#hparser{body_state=
				{stream, fun te_chunked/2, {0, 0}, fun ce_identity/1}});
		_ when Length =:= 0 orelse Method =:= <<"HEAD">> ->
            done;
        _ ->
		    parse_body(St#hparser{body_state=
						{stream, fun te_identity/2, {0, Length},
						 fun ce_identity/1}})
	end;
parse_body(St=#hparser{buffer=Buffer, body_state={stream, _, _, _}})
		when Buffer =/= <<>> ->
	transfer_decode(Buffer, St#hparser{buffer= <<>>});
parse_body(St=#hparser{body_state={stream, _, _, _}, buffer=Buffer}) ->
    transfer_decode(Buffer, St);
parse_body(St=#hparser{body_state=done}) ->
	{done, St}.



-spec transfer_decode(binary(), #hparser{})
                     -> {ok, binary(), #hparser{}} | {error, atom()}.
transfer_decode(Data, St=#hparser{
                body_state={stream, TransferDecode,
                                    TransferState, ContentDecode},
                buffer=Buf}) ->
    case TransferDecode(Data, TransferState) of
        {ok, Data2, TransferState2} ->
            content_decode(ContentDecode, Data2,
                           St#hparser{body_state= {stream,
                                                      TransferDecode,
                                                      TransferState2,
                                                      ContentDecode}});
        {ok, Data2, Rest, TransferState2} ->
            content_decode(ContentDecode, Data2,
                           St#hparser{buffer=Rest,
                                         body_state={stream,
                                                     TransferDecode,
                                                     TransferState2,
                                                     ContentDecode}});
        {chunk_done, Rest} ->
            {done, Rest};
        {chunk_ok, Chunk, Rest} ->
            {ok, Chunk, fun() -> execute(St#hparser{buffer=Rest}) end};
        more ->
            {more, fun(Bin) ->
                        incomplete_handler(Bin, St#hparser{buffer=Data})
                end, Buf};
        {done, Rest} ->
            {done, Rest};
        {done, Data2, _Rest} ->
            content_decode(ContentDecode, Data2, St);
        {done, Data2, _Length, _Rest} ->
            content_decode(ContentDecode, Data2, St);
        done ->
            done;
        {error, Reason} ->
            {error, Reason}
    end.


%% @todo Probably needs a Rest.
-spec content_decode(fun(), binary(), #hparser{})
	-> {ok, binary(), #hparser{}} | {error, atom()}.
content_decode(ContentDecode, Data, St) ->
	case ContentDecode(Data) of
        {ok, Data2} -> {ok, Data2, fun() -> execute(St) end};
		{error, Reason} -> {error, Reason}
	end.



%% @doc Decode a stream of chunks.
-spec te_chunked(binary(), any())
                -> more | {ok, binary(), {non_neg_integer(), non_neg_integer()}}
                       | {ok, binary(), binary(),  {non_neg_integer(), non_neg_integer()}}
                       | {done, non_neg_integer(), binary()} | {error, badarg}.
te_chunked(<<>>, _) ->
    done;
te_chunked(Data, _) ->
    case read_size(Data) of
        {ok, 0, Rest} ->
            {chunk_done, Rest};
        {ok, Size, Rest} ->
            case read_chunk(Rest, Size) of
                {ok, Chunk, Rest1} ->
                    {chunk_ok, Chunk, Rest1};
                eof ->
                    more
            end;
        eof ->
            more
    end.

%% @doc Decode an identity stream.
-spec te_identity(binary(), {non_neg_integer(), non_neg_integer()})
	-> {ok, binary(), {non_neg_integer(), non_neg_integer()}}
	| {done, binary(), non_neg_integer(), binary()}.
te_identity(Data, {Streamed, Total})
		when Streamed + byte_size(Data) < Total ->
	{ok, Data, {Streamed + byte_size(Data), Total}};
te_identity(Data, {Streamed, Total}) ->
	Size = Total - Streamed,
	<< Data2:Size/binary, Rest/binary >> = Data,
	{done, Data2, Total, Rest}.

%% @doc Decode an identity content.
-spec ce_identity(binary()) -> {ok, binary()}.
ce_identity(Data) ->
	{ok, Data}.


read_size(Data) ->
    case read_size(Data, [], true) of
        {ok, Line, Rest} ->
            case io_lib:fread("~16u", Line) of
                {ok, [Size], []} ->
                    {ok, Size, Rest};
                _ ->
                    {error, {poorly_formatted_size, Line}}
            end;
        Err ->
            Err
    end.

read_size(<<>>, _, _) ->
    eof;

read_size(<<"\r\n", Rest/binary>>, Acc, _) ->
    {ok, lists:reverse(Acc), Rest};

read_size(<<$;, Rest/binary>>, Acc, _) ->
    read_size(Rest, Acc, false);

read_size(<<C, Rest/binary>>, Acc, AddToAcc) ->
    case AddToAcc of
        true ->
            read_size(Rest, [C|Acc], AddToAcc);
        false ->
            read_size(Rest, Acc, AddToAcc)
    end.

read_chunk(Data, Size) ->
    case Data of
        <<Chunk:Size/binary, "\r\n", Rest/binary>> ->
            {ok, Chunk, Rest};
        <<_Chunk:Size/binary, _Rest/binary>> when size(_Rest) >= 2 ->
            {error, poorly_formatted_chunked_size};
        _ ->
            eof
    end.

%% @private

parse_options([], St) ->
    St;
parse_options([auto | Rest], St) ->
    parse_options(Rest, St#hparser{type=auto});
parse_options([request | Rest], St) ->
    parse_options(Rest, St#hparser{type=request});
parse_options([response | Rest], St) ->
    parse_options(Rest, St#hparser{type=response});
parse_options([{max_line_length, MaxLength} | Rest], St) ->
    parse_options(Rest, St#hparser{max_line_length=MaxLength});
parse_options([{max_empty_lines, MaxEmptyLines} | Rest], St) ->
    parse_options(Rest, St#hparser{max_empty_lines=MaxEmptyLines});
parse_options([_ | Rest], St) ->
    parse_options(Rest, St).