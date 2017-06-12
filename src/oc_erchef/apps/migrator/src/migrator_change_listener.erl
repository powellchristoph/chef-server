%% ex: ts=4 sw=4 et
%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-

-module(migrator_change_listener).
-behaviour(gen_server).

-define(SERVER, ?MODULE).

-export([%% API functions
         start_link/0,

         %% gen_server behaviour
         init/1,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         handle_info/2,
         code_change/3]).

-define(POLL_INTERVAL_MS, 250).

% This module simply polls for new transactions using a direct sql connection as superuser.
% The end of this first phase will have it running on localhost, dumping data into a local copy of the DB.
% Once parsing/statements are worked out, the next step is a remote DB associated with a chef server,
% perhaps with a manual restore of bifrost and cookbooks.
%
% Because this is PoC/spike work, you won't find new tests here yet.
%
% Some thoughts:
%  - currently this does all parsing in the same proc. We may want to farm that out to
%    one or more workers, which can sync and sequence on the trans id.  Particularly once we're
%    doing this for multiple DBs.
%  - This does attempt to prevent transaction loss by 'peek'ing one change at a time, then
%    'get'ing it to clear it from the replication slot.  Errors that cause the supervisor to give up
%    due to restart intensity limits would be considered fatal to the migration.
%  - I used epgsql directly:
%       * sqerl only supports one DB connection - presently that's opscode_chef as the erchef user;
%         as an alterntiave I could have used sqerl for the polling by giving the erchef user
%         replication privileges, though initially the direction was a bit different and that made less sense.
%       * we don't need pooling.  There's a dedicated connection to siphone dat from the logical repl slot
%         and that's it.
%       * When/if we move this to its own standalone service, that's a thing to revisit and check perf impact of.
%
% Open questions:
%  - how do we handle updatesa that are done as part of triggers or stored procedures?
%    We don't get a record of the trigger/proc run - instead we get the individual transaction(s) generated
%    We can just run them directly to get the right data, but that means that the receiving DB
%    should have its own triggers disabled. This is not used in a lot of spots (artifacts, user/client creation
%    ar ethe two that comes to mind), but it exists. IIRC bifrost makes heavier use of stored procs.
%
%
% Things to consider:
%  - Because this application would need to run across all databases to sync
%    inbound updates for ocid, bifrost, erchef, and bookshelf we will want to move it to its own service.
%  - this is currently moving in the direction where chef-server.old handles the inbound changes from the repl
%    slot and applies them to the remote DB directly.
%       * reverse so that the remote system pulls the changes from the slot and applies them locally. Likely to be
%         more overhead here, particularly with 'peek' then 'get' approach to preserve unprocessed transactions.
%       * if exposed ports are a problem we could also do this through other chef-server->chef-server comm channel
%         over SSL (API, etc).  I don't recommend shipping terms over erlang RPC - reading suggests
%         people with more experience at this have found it doesn't handle large traffic well because it's a shared
%         connection for all erl RPC.
%  - we don't currently pay attention to tx id  - it's possible that some stored procs are nesting transactions
%    which we're not doing anything special for. I don't think any of our procs use nested transactions,
%    so this shouldn't be a problem...
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% gen_server functions
init(_Args) ->
    {ok, Password} = chef_secrets:get(<<"postgresql">>, <<"db_superuser_password">>),
    {ok, Conn} = epgsql:connect("127.0.0.1", "opscode-pgsql", Password, [{database, "opscode_chef"}]),
    % Not capturing the ref, we won't be canceling it. The timer is cleaned up automatically
    % after it expires.
    erlang:send_after(?POLL_INTERVAL_MS, ?SERVER, poll_interval_expired),
    {ok, #{conn => Conn}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll_interval_expired, #{conn := Conn} = State) ->
    check_and_process_incoming_data(Conn),
    erlang:send_after(?POLL_INTERVAL_MS, ?SERVER, poll_interval_expired),
    {noreply, State};
handle_info({_Port, {data, _Message}}, State) ->
    {noreply, State}.


terminate(_Reason, #{conn := Conn}) ->
    % Just in case we failed for a reason other than postgres connection issues,
    % don't leak our connection
    epgsql:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal
check_and_process_incoming_data(Conn) ->
    % If this fails, this proc will terminate and we'll make a new connection.
    %
    % The parmeter '1' is for 'upto_nchanges' to ensure that we only get one transaction
    % at a time , just to keep this a bit simpler for now. I recently added that change,
    % and have not verified if "1" means "one completed transaction" or "one atomic change to the db".
    %
    % This  is using `peek_changes` to preview the data, and `get_changes` after we have processed a change,
    % allowing us to use the logical replication slot itself as our queue.  This has the overhead
    % of requesting each change twice, but without the 'get' to clear completed TXs,
    % the logical slot will eventually expand to fill the disk.
    %
    % TODO: The slot name 'regression_slot' was copy-pasted out of the original PG examples...
    Query = <<"select * from pg_logical_slot_peek_changes('regression_slot', NULL, 1,"
              "'include-xids','1','force-binary','0','skip-empty-xacts', '1')">>,

    % 'Data' is a list of tuples returns from the query:
    {ok, _Fields, Data} = epgsql:squery(Conn, Query),
    % Again, we'll want better error handling. Or... any at all, really - in this case,
    % we'll care about repeated failures on the same TX, as opposed to transient/postgres momentarily went
    % away issues.
    NumChanges = length(Data),
    ok = decode_and_apply(Data),
    clear_replication_slot(Conn, NumChanges),
    ok.

% this performs a pg_logical_slot_get_changes request to remove the TX we successfully
% applied from the replicatoin slot.
clear_replication_slot(Conn, ExpectedChangeCount) ->
    Query = <<"select * from pg_logical_slot_get_changes('regression_slot', NULL, 1,"
              "'include-xids','1','force-binary','0','skip-empty-xacts', '1')">>,
    {ok, _Fields, Data} = epgsql:squery(Conn, Query),
    ActualChangeCount = length(Data),
    case ExpectedChangeCount == ActualChangeCount of
        true -> ok;
        false ->
            lager:error("Expected ~p changes, got ~p", [ExpectedChangeCount, ActualChangeCount])
    end,
    ok.

decode_and_apply([TX|Rest]) ->
    case migrator_decoder:parse(TX) of
        {error, {unknown_type, Type}} ->
            %%  this could be a sequence, or other unhandled type.
            lager:error("Could not decode transaction, unknown entity type ~p", [Type]);
        {error, {unknown_entity, SchemaAndTable}} ->
            %% Haven't worked on other schemas here - the only one I expect we'll use is sqitch,
            %% which we can ignore if we continue to allow sqitch to manage the schema directly on the
            %% new system (and if migration versions match...)
            %% Caveat: make sure the server is not in sync mode during a `chef-server-ctl upgrade`...
            %%
            lager:error("Could not decode transaction, unsupported schema: ~p", [SchemaAndTable]);
        {ok, {Marker, _TXID}} when Marker == begin_tx, Marker== end_tx->
            % TODO:
            lager:info("Skipping ~p, no action required until we start caring about transactions....", [Marker]);
        {ok, Decoded} ->
            % This will apply the change to the target database.
            % This will crash the listener if we fail to apply a change.
            ok = migrator_target_db:execute(Decoded)
    end,
    decode_and_apply(Rest);
decode_and_apply([]) ->
    ok.

%% This was the original code that used a port to monitor for changes.
%% This works, but there's less parsing trouble (newlines) we use epgsql to ask directly. Just wanted it captured
%% in at least one commit in case we want to look closer at it for any reason. Feel free to delete...
% init(_Args) ->
%     CommandArgs = ["--start", "-h", "127.0.0.1",
    %                "-U", "opscode-pgsql",
    %                "-S", "regression_slot", % slot name - you *did* remember to run
    %                % SELECT * FROM pg_create_logical_replication_slot('migration_slot', 'test_decoding');
    %                %                        % didn't you? Come back when you're ready.
    %                "-f", "-", % out to stdout
    %                "-d", "opscode_chef",
    %                % The options below are taken from here:
    %                % https://doxygen.postgresql.org/test__decoding_8c.html#ae9ad7b4e35a8ca2df15233e16557cbcf

%                "-o", "skip-empty-xacts",
    %                "-o", "force-binary", % experimenting to see the diff it makes
    %                "--no-password"],
    %
    % PortSettings = [
    %                 {args,CommandArgs},
    %                 {env, [{"PGPASSWORD", binary_to_list(Password)}]},
    %                 use_stdio,
    %                 binary,
    %                 {line, 1024}
    %                ],
    % % Observation - when too much data backlogs in stdout, pg_recvlogical fails to write?!
    % Port = open_port({spawn_executable,
    %                   "/opt/opscode/embedded/bin/pg_recvlogical"}, PortSettings),
    % {ok, #{port => Port, txid => undefined}}.