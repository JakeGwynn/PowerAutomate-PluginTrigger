using System;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace FlowTrigger.Plugins.PerfTest
{
    /// <summary>
    /// PERF-TESTING COPY of ../../plugin/RunFlowDispatcher.cs. Behaves
    /// identically to the original in every way that affects the caller's
    /// response - same PreValidation-stage requirement, same raise-then-poll
    /// logic, same output shape - with one addition: it captures a precise
    /// UTC timestamp at every meaningful step of its own execution and, once
    /// the call is finished (success OR timeout), writes ONE row describing
    /// them to a brand-new table this copy alone uses,
    /// &lt;prefix&gt;_calltelemetry (see ../deploy/Deploy-PerfTestEnvironment.ps1).
    ///
    /// This lets deploy/Get-PerfTestBreakdown.ps1 decompose the round trip
    /// into precise sub-phases instead of the coarse "dispatch vs flow vs
    /// poll" split the production repo's own (now-removed) load-testing docs
    /// used:
    ///
    ///   T1 dispatcher entry      -&gt; T2 before raise   : dispatcher's own setup
    ///   T2 before raise          -&gt; T3 after raise     : the raise-event call itself
    ///   T3 after raise           -&gt; T4 poll loop entry : trivial, sanity-check only
    ///   T3/T4                    -&gt; worker flow's own run start (Flow API) : the
    ///                               one span this plug-in cannot instrument directly -
    ///                               entirely inside Power Automate's own trigger-dispatch
    ///                               pipeline
    ///   flow run start -&gt; end   : the flow's own logic (unchanged from before)
    ///   flowresult row's own precise write timestamp -&gt; T5 result detected : true
    ///                               poll-detect latency, no longer limited by
    ///                               Dataverse's 1-second createdon resolution
    ///   T5 result detected       -&gt; T6 dispatcher exit  : wrap-up (JSON build +
    ///                               SharedVariables set), captured BEFORE the
    ///                               telemetry write itself so the telemetry
    ///                               mechanism's own cost never pollutes this number
    ///   T6 dispatcher exit (server) -&gt; caller's own CompletionTimestamp (client) :
    ///                               RunFlowMainOperationTelemetry's relay + platform
    ///                               response marshaling - RunFlowMainOperationTelemetry
    ///                               is an UNMODIFIED, uninstrumented copy specifically so
    ///                               this span keeps measuring the real trivial-relay cost,
    ///                               not this file's own instrumentation.
    ///
    /// All of T1-T6 are read from this SAME plug-in execution's own clock, so
    /// every delta between them is clock-skew-free. Only the two boundaries
    /// that cross into a caller's or the flow runtime's own clock (client
    /// RequestStartTimestamp/CompletionTimestamp, and the Flow API's run
    /// start/end) carry the usual small clock-skew caveat - documented in
    /// perf-testing/README.md.
    ///
    /// If writing the telemetry row itself fails for any reason (e.g. the
    /// table isn't provisioned yet), that failure is caught and traced, and
    /// this method still returns the caller's normal response - a broken
    /// telemetry mechanism must never break the very call it's measuring.
    /// </summary>
    public class RunFlowDispatcherTelemetry : IPlugin
    {
        internal const string DefaultPublisherPrefix = "flowperf";

        private readonly string _callerMessagePrefix;
        private readonly string _eventMessagePrefix;
        private readonly string _resultTableLogicalName;
        private readonly string _correlationIdField;
        private readonly string _statusField;
        private readonly string _messageField;
        private readonly string _writtenUtcField;
        private readonly string _telemetryTableLogicalName;
        private readonly string _publisherPrefix;

        internal const string SharedVariablesKey = "FlowTrigger_OutputJson";

        // Identical to the original - see plugin/RunFlowDispatcher.cs remarks
        // for why these specific values were chosen.
        private static readonly TimeSpan PollBudget = TimeSpan.FromSeconds(110);
        private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

        private static readonly Regex BatchSizePattern = new Regex("\"batch\"\\s*:\\s*(\\d+)", RegexOptions.Compiled);

        public RunFlowDispatcherTelemetry(string unsecureConfig, string secureConfig)
        {
            var prefix = string.IsNullOrWhiteSpace(unsecureConfig) ? DefaultPublisherPrefix : unsecureConfig.Trim();
            _publisherPrefix = prefix;

            _callerMessagePrefix = prefix + "_RunFlow";
            _eventMessagePrefix = prefix + "_OnFlowRequested";
            _resultTableLogicalName = prefix + "_flowresult";
            _correlationIdField = prefix + "_correlationid";
            _statusField = prefix + "_status";
            _messageField = prefix + "_message";
            _writtenUtcField = prefix + "_writtenutc";
            _telemetryTableLogicalName = prefix + "_calltelemetry";
        }

        public void Execute(IServiceProvider serviceProvider)
        {
            if (serviceProvider == null)
            {
                throw new ArgumentNullException(nameof(serviceProvider));
            }

            // T1: the very first thing this method does, before any service
            // resolution - the closest this code can get to "the plug-in
            // pipeline handed control to this step."
            var t1DispatcherEntry = DateTime.UtcNow;

            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
            var tracing = (ITracingService)serviceProvider.GetService(typeof(ITracingService));
            var factory = (IOrganizationServiceFactory)serviceProvider.GetService(typeof(IOrganizationServiceFactory));

            // Same rationale as the original - raised as the real caller, not
            // elevated. See plugin/RunFlowDispatcher.cs remarks.
            var callerService = factory.CreateOrganizationService(context.UserId);

            // Same rationale as the original for the elevated read - also
            // used here to write this copy's own telemetry row, since that
            // write is system plumbing (recording HOW LONG something took),
            // not a new authorization decision, and doing it elevated avoids
            // needing to grant every caller role Create on a table that only
            // exists for this perf-testing copy in the first place.
            var elevatedService = factory.CreateOrganizationService(null);

            var inputJson = context.InputParameters.Contains("InputJson")
                ? context.InputParameters["InputJson"] as string ?? string.Empty
                : string.Empty;
            var batchSize = TryParseBatchSize(inputJson);

            var consumerId = ResolveConsumerId(context.MessageName);
            var eventMessageName = ResolveEventMessageName(context.MessageName);
            var correlationId = Guid.NewGuid();

            tracing.Trace(
                "RunFlowDispatcherTelemetry: caller message '{0}' -> event message '{1}' (correlation {2})",
                context.MessageName, eventMessageName, correlationId);

            var t2BeforeRaise = DateTime.UtcNow;
            RaiseEvent(callerService, eventMessageName, inputJson, correlationId);
            var t3AfterRaise = DateTime.UtcNow;

            // T4 is expected to sit right on top of T3 - it exists purely as
            // a sanity check that nothing non-trivial happens between "event
            // raised" and "poll loop begins."
            var t4PollLoopEntry = DateTime.UtcNow;

            var poll = PollForResult(elevatedService, tracing, correlationId);

            // T6 captured BEFORE the telemetry write, deliberately - this
            // value describes when the dispatcher's REAL work finished, not
            // including the cost of recording that it finished.
            var t6DispatcherExit = DateTime.UtcNow;

            TryWriteTelemetry(elevatedService, tracing, correlationId, consumerId, batchSize,
                t1DispatcherEntry, t2BeforeRaise, t3AfterRaise, t4PollLoopEntry,
                poll, t6DispatcherExit);

            // Handed off via SharedVariables - identical mechanism to the
            // original. See plugin/RunFlowDispatcher.cs remarks for why
            // context.OutputParameters isn't set directly from here.
            context.SharedVariables[SharedVariablesKey] = poll.OutputJson;
        }

        internal string ResolveConsumerId(string callerMessageName)
        {
            if (string.IsNullOrEmpty(callerMessageName))
            {
                throw new InvalidPluginExecutionException("Unexpected empty message name.");
            }

            if (string.Equals(callerMessageName, _callerMessagePrefix, StringComparison.OrdinalIgnoreCase))
            {
                return "Default";
            }

            var suffix = callerMessageName.Substring(_callerMessagePrefix.Length);
            if (!suffix.StartsWith("_", StringComparison.Ordinal))
            {
                throw new InvalidPluginExecutionException(
                    $"RunFlowDispatcherTelemetry does not know how to route caller message '{callerMessageName}'. " +
                    $"Expected '{_callerMessagePrefix}' or '{_callerMessagePrefix}_<Consumer>'.");
            }

            return suffix.Substring(1);
        }

        internal string ResolveEventMessageName(string callerMessageName)
        {
            var consumerId = ResolveConsumerId(callerMessageName);
            return string.Equals(consumerId, "Default", StringComparison.OrdinalIgnoreCase)
                ? _eventMessagePrefix
                : _eventMessagePrefix + "_" + consumerId;
        }

        private static int? TryParseBatchSize(string inputJson)
        {
            if (string.IsNullOrEmpty(inputJson))
            {
                return null;
            }

            var match = BatchSizePattern.Match(inputJson);
            if (match.Success && int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
            {
                return value;
            }
            return null;
        }

        private static void RaiseEvent(IOrganizationService service, string eventMessageName, string inputJson, Guid correlationId)
        {
            try
            {
                var raiseRequest = new OrganizationRequest(eventMessageName)
                {
                    ["InputJson"] = inputJson,
                    ["CorrelationId"] = correlationId.ToString()
                };
                service.Execute(raiseRequest);
            }
            catch (Exception ex)
            {
                throw new InvalidPluginExecutionException(
                    $"RunFlowDispatcherTelemetry could not raise business event '{eventMessageName}'. Confirm the event " +
                    "Custom API and its Catalog Assignment exist for this consumer, and that the worker flow's " +
                    "trigger is enabled. " + ex.Message, ex);
            }
        }

        /// <summary>
        /// Carries back everything PollForResult learned, so Execute can hand
        /// it all to TryWriteTelemetry in one shot.
        /// </summary>
        private sealed class PollOutcome
        {
            public string OutputJson;
            public string Status;
            public int PollAttempts;
            public string ResultRowCreatedOn;
            public string ResultRowWrittenUtc;
            public DateTime? ResultDetectedUtc;
        }

        private PollOutcome PollForResult(IOrganizationService service, ITracingService tracing, Guid correlationId)
        {
            var deadline = DateTime.UtcNow.Add(PollBudget);
            var attempts = 0;

            while (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(PollInterval);
                attempts++;

                var query = new QueryExpression(_resultTableLogicalName)
                {
                    ColumnSet = new ColumnSet(_statusField, _messageField, _writtenUtcField, "createdon"),
                    TopCount = 1
                };
                query.Criteria.AddCondition(_correlationIdField, ConditionOperator.Equal, correlationId.ToString());
                query.AddOrder("createdon", OrderType.Descending);

                var results = service.RetrieveMultiple(query);
                if (results.Entities.Count > 0)
                {
                    var resultDetectedUtc = DateTime.UtcNow;
                    var row = results.Entities[0];
                    var status = row.GetAttributeValue<string>(_statusField) ?? "Succeeded";
                    var message = row.GetAttributeValue<string>(_messageField) ?? string.Empty;
                    var createdOn = row.Contains("createdon") ? row.GetAttributeValue<DateTime>("createdon").ToString("o", CultureInfo.InvariantCulture) : null;
                    var writtenUtc = row.GetAttributeValue<string>(_writtenUtcField);

                    tracing.Trace("RunFlowDispatcherTelemetry: result row found for correlation {0}, status={1}, attempts={2}", correlationId, status, attempts);

                    return new PollOutcome
                    {
                        OutputJson = BuildJson(status, message),
                        Status = status,
                        PollAttempts = attempts,
                        ResultRowCreatedOn = createdOn,
                        ResultRowWrittenUtc = writtenUtc,
                        ResultDetectedUtc = resultDetectedUtc
                    };
                }
            }

            tracing.Trace("RunFlowDispatcherTelemetry: poll budget exhausted for correlation {0} after {1} attempts", correlationId, attempts);
            return new PollOutcome
            {
                OutputJson = BuildJson(
                    "Timeout",
                    "The flow did not write a result within the allotted time. It may still be running - check the flow's run history."),
                Status = "Timeout",
                PollAttempts = attempts,
                ResultRowCreatedOn = null,
                ResultRowWrittenUtc = null,
                ResultDetectedUtc = null
            };
        }

        private void TryWriteTelemetry(
            IOrganizationService service, ITracingService tracing, Guid correlationId, string consumerId, int? batchSize,
            DateTime t1, DateTime t2, DateTime t3, DateTime t4, PollOutcome poll, DateTime t6)
        {
            try
            {
                var entity = new Entity(_telemetryTableLogicalName);

                SetField(entity, "correlationid", correlationId.ToString());
                SetField(entity, "consumer", consumerId);
                if (batchSize.HasValue)
                {
                    SetField(entity, "batchsize", batchSize.Value);
                }
                SetField(entity, "t1dispatcherentry", ToIso(t1));
                SetField(entity, "t2beforeraise", ToIso(t2));
                SetField(entity, "t3afterraise", ToIso(t3));
                SetField(entity, "t4pollloopentry", ToIso(t4));
                SetField(entity, "pollattempts", poll.PollAttempts);
                if (poll.ResultDetectedUtc.HasValue)
                {
                    SetField(entity, "t5resultdetected", ToIso(poll.ResultDetectedUtc.Value));
                }
                if (poll.ResultRowCreatedOn != null)
                {
                    SetField(entity, "resultrowcreatedon", poll.ResultRowCreatedOn);
                }
                if (poll.ResultRowWrittenUtc != null)
                {
                    SetField(entity, "resultrowwrittenutc", poll.ResultRowWrittenUtc);
                }
                SetField(entity, "t6dispatcherexit", ToIso(t6));
                SetField(entity, "outcome", poll.Status);

                service.Create(entity);
            }
            catch (Exception ex)
            {
                // A broken telemetry mechanism must never break the call it's
                // measuring - trace and move on, the caller still gets their
                // normal response either way.
                tracing.Trace("RunFlowDispatcherTelemetry: could not write telemetry row for correlation {0}: {1}", correlationId, ex.Message);
            }
        }

        private void SetField(Entity entity, string bareFieldName, object value)
        {
            entity[FieldName(bareFieldName)] = value;
        }

        private string FieldName(string bareFieldName)
        {
            // Every column on _telemetryTableLogicalName follows the same
            // "<prefix>_<bareFieldName>" convention as every other table in
            // this solution (see _correlationIdField etc. above).
            return _publisherPrefix + "_" + bareFieldName;
        }

        private static string ToIso(DateTime value)
        {
            return value.ToString("o", CultureInfo.InvariantCulture);
        }

        private static string BuildJson(string status, string message)
        {
            return string.Format(
                CultureInfo.InvariantCulture,
                "{{\"status\":\"{0}\",\"message\":\"{1}\"}}",
                JsonEscape(status),
                JsonEscape(message));
        }

        private static string JsonEscape(string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return string.Empty;
            }

            return value
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"")
                .Replace("\r", "\\r")
                .Replace("\n", "\\n")
                .Replace("\t", "\\t");
        }
    }
}
