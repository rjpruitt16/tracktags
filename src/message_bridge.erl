-module(message_bridge).
-export([receive_and_convert/1]).

receive_and_convert(Timeout) ->
    receive
        % Handle tick messages from ClockActor
        {tick_1s, Timestamp} when is_binary(Timestamp) -> 
            {ok, {timestamp_message, <<"tick_1s">>, Timestamp}};
        {tick_5s, Timestamp} when is_binary(Timestamp) -> 
            {ok, {timestamp_message, <<"tick_5s">>, Timestamp}};
        {tick_30s, Timestamp} when is_binary(Timestamp) -> 
            {ok, {timestamp_message, <<"tick_30s">>, Timestamp}};
        
        % Handle Elixir maps (they come as Erlang maps)
        #{<<"tick_type">> := TickType, <<"timestamp">> := Timestamp} ->
            {ok, {timestamp_message, TickType, Timestamp}};
            
        % Handle string messages
        Message when is_binary(Message) ->
            {ok, {text_message, Message}};
            
        % Catch all unknown messages
        Other ->
            io:format("Unknown message type: ~p~n", [Other]),
            {ok, unknown}
    after Timeout ->
        {error, nil}
    end.
