using System;
using System.Globalization;
using System.Threading;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace FlowTrigger.Plugins
{
    /// <summary>
    /// Shared plug-in type behind every "caller" Custom API in this solution
    /// (`&lt;prefix&gt;_RunFlow` is the default/unsuffixed consumer,
    /// `&lt;prefix&gt;_RunFlow_&lt;Consumer&gt;` for every additional consumer
    /// defined in deploy/consumers.json). `&lt;prefix&gt;` is this
    /// deployment's publisher prefix - supplied at registration time via this
    /// plug-in step's Configuration string (see the constructor below), so
    /// one compiled assembly works for any publisher prefix with no rebuild.
    ///
    /// One plug-in type backs any number of Custom APIs - each Custom API is
    /// its own "front door" with its own ExecutePrivilegeName (see
    /// deploy/Deploy-FlowTriggerSolution.ps1), so different callers/flows can
    /// be granted access independently via distinct Security Roles, while all
    /// of them share this single dispatcher implementation.
    ///
    /// Design: the caller Custom API is intentionally a *synchronous*
    /// Dataverse message (not an HTTP trigger) so that Dataverse's IP
    /// firewall - which only protects the Web API surface, not a flow's own
    /// HTTP trigger endpoint - actually applies to it. This plug-in raises a
    /// business-event Custom API that a Power Automate flow subscribes to via
    /// "When an action is performed", then blocks (polling, not async) for up
    /// to <see cref="PollBudget"/> so the original caller gets a synchronous
    /// response in the same HTTP request/response cycle.
    ///
    /// CRITICAL: this type MUST be registered on the caller Custom API's
    /// message at the <b>PreValidation</b> stage (10), NOT bound as the
    /// Custom API's Main Operation implementation (PluginTypeId), and NOT at
    /// PreOperation/PostOperation. Per Microsoft's own documented pipeline
    /// transaction model
    /// (https://learn.microsoft.com/power-apps/developer/data-platform/scalable-customization-design/database-transactions):
    /// a synchronous step registered at PreValidation runs with NO enclosing
    /// database transaction (for a top-level request with no existing parent
    /// transaction, which is exactly this caller Custom API's scenario) -
    /// every message it issues via IOrganizationService.Execute is committed
    /// independently, immediately. Main Operation/PreOperation/PostOperation
    /// steps, by contrast, run INSIDE the platform's core operation
    /// transaction, which only commits once the top-level Execute() call
    /// returns.
    ///
    /// This distinction is the entire reason a *separate*, trivial
    /// <see cref="RunFlowMainOperation"/> type exists: if this dispatcher's
    /// raise-event-then-poll logic ran as the Main Operation implementation
    /// instead, the business event it raises (and the resulting async job
    /// that actually delivers it to a subscribed Power Automate flow) would
    /// never become visible to that flow until this plugin's own Execute()
    /// returns - but Execute() can't return until the poll finds a result -
    /// which can't exist until the flow actually runs - which can't happen
    /// until the transaction commits - which can't happen until Execute()
    /// returns. A genuine self-deadlock: every call reliably times out at
    /// just past whatever PollBudget is configured, yet the flow completes
    /// correctly moments after the poll gives up and Execute() finally
    /// returns/commits. Splitting the real work out to PreValidation removes
    /// the enclosing transaction entirely, so the raised event can be
    /// dispatched to the flow immediately while this plugin is still
    /// polling. See docs/ARCHITECTURE.md for the full write-up.
    /// </summary>
    public class RunFlowDispatcher : IPlugin
    {
        /// <summary>
        /// Publisher prefix assumed when no step-specific Configuration
        /// string is supplied at all. Every deployment created by
        /// Deploy-FlowTriggerSolution.ps1 passes its own -PublisherPrefix
        /// through Configuration (see the constructor), so this default only
        /// matters for a step registered some other way.
        /// </summary>
        internal const string DefaultPublisherPrefix = "flowtrig";

        private readonly string _callerMessagePrefix;
        private readonly string _eventMessagePrefix;
        private readonly string _resultTableLogicalName;
        private readonly string _correlationIdField;
        private readonly string _statusField;
        private readonly string _messageField;

        /// <summary>
        /// SharedVariables key used to hand the computed OutputJson off to
        /// <see cref="RunFlowMainOperation"/> (see that type's remarks for why
        /// this hand-off exists instead of setting context.OutputParameters
        /// directly from this PreValidation-stage plugin). This is an
        /// in-memory dictionary key local to one pipeline execution, not a
        /// Dataverse schema name - it does not need to vary with the
        /// publisher prefix.
        /// </summary>
        internal const string SharedVariablesKey = "FlowTrigger_OutputJson";

        // Kept under Dataverse's ~2 minute synchronous message execution cap,
        // leaving headroom for request/response overhead end-to-end. Live
        // testing showed the async dispatch *queue* itself (before a
        // subscriber's plugin/flow even starts running) can take ~90-105s on
        // its own, on top of whatever the subscriber's own logic takes - 100s
        // was still cutting that too close (observed real flow completions
        // landing at 101-105s wall-clock). 110s leaves ~10s of headroom under
        // the hard cap for request/response overhead - this is a tight
        // margin, so a further-delayed dispatch can still time out.
        private static readonly TimeSpan PollBudget = TimeSpan.FromSeconds(110);
        private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

        /// <summary>
        /// Dataverse's plug-in loader calls this two-argument constructor
        /// automatically whenever the step's Configuration is set (see
        /// SdkMessageProcessingStep.Configuration) -
        /// Deploy-FlowTriggerSolution.ps1 sets it to this deployment's
        /// -PublisherPrefix when registering RunFlowDispatcher's
        /// PreValidation step. This is the mechanism that lets one compiled
        /// assembly serve any publisher prefix without a rebuild: every
        /// schema name this type needs is computed once here, from that
        /// string, rather than hardcoded.
        /// </summary>
        public RunFlowDispatcher(string unsecureConfig, string secureConfig)
        {
            var prefix = string.IsNullOrWhiteSpace(unsecureConfig) ? DefaultPublisherPrefix : unsecureConfig.Trim();

            _callerMessagePrefix = prefix + "_RunFlow";
            _eventMessagePrefix = prefix + "_OnFlowRequested";
            _resultTableLogicalName = prefix + "_flowresult";
            _correlationIdField = prefix + "_correlationid";
            _statusField = prefix + "_status";
            _messageField = prefix + "_message";
        }

        public void Execute(IServiceProvider serviceProvider)
        {
            if (serviceProvider == null)
            {
                throw new ArgumentNullException(nameof(serviceProvider));
            }

            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
            var tracing = (ITracingService)serviceProvider.GetService(typeof(ITracingService));
            var factory = (IOrganizationServiceFactory)serviceProvider.GetService(typeof(IOrganizationServiceFactory));

            // The business event is raised AS the real caller (not elevated) so
            // they remain the actor of record for audit/traceability. The
            // event Custom API's ExecutePrivilegeName is set (by
            // Deploy-FlowTriggerSolution.ps1) to this same consumer's
            // marker-table privilege - the exact privilege this caller
            // already had to hold to reach this code via the caller Custom
            // API's own ExecutePrivilegeName check. Raising the event as
            // context.UserId therefore passes that check trivially for a
            // legitimate caller, while closing the ability for anyone who
            // does NOT hold that privilege to bypass the caller Custom API
            // entirely and invoke the event Custom API directly.
            var callerService = factory.CreateOrganizationService(context.UserId);

            // The result table's rows are written by the worker flow (a
            // different identity entirely) and correlate purely by a GUID
            // this plug-in just generated - the calling user never owns and
            // can never be meaningfully "shared" one in advance. Reading it
            // back is system plumbing, not a new authorization decision (the
            // real decision - "may this caller invoke this consumer at all" -
            // already happened via ExecutePrivilegeName before this code
            // ever ran), so this one read is intentionally elevated. This
            // also avoids having to grant every caller role a broad,
            // Global-depth Read on the result table just to see their own
            // result, which would let any caller directly query *every*
            // consumer's results/messages via the Web API - an unrelated
            // information leak with no corresponding benefit.
            var elevatedService = factory.CreateOrganizationService(null);

            var inputJson = context.InputParameters.Contains("InputJson")
                ? context.InputParameters["InputJson"] as string ?? string.Empty
                : string.Empty;

            var eventMessageName = ResolveEventMessageName(context.MessageName);
            var correlationId = Guid.NewGuid();

            tracing.Trace(
                "RunFlowDispatcher: caller message '{0}' -> event message '{1}' (correlation {2})",
                context.MessageName, eventMessageName, correlationId);

            RaiseEvent(callerService, eventMessageName, inputJson, correlationId);

            var outputJson = PollForResult(elevatedService, tracing, correlationId);

            // Handed off via SharedVariables, NOT context.OutputParameters -
            // this plugin is registered at PreValidation, which per
            // Microsoft's pipeline docs is not guaranteed to have its
            // OutputParameters changes flow through to the actual message
            // response. RunFlowMainOperation (registered as the Custom API's
            // real Main Operation implementation) reads this and is the one
            // that actually sets OutputParameters. context.SharedVariables is
            // shared across all steps in the same pipeline execution
            // regardless of stage, so this hand-off is reliable.
            context.SharedVariables[SharedVariablesKey] = outputJson;
        }

        /// <summary>
        /// Extracts the bare consumer id from a caller message name, e.g. (for
        /// publisher prefix "flowtrig"):
        ///   flowtrig_RunFlow          -&gt; "Default"
        ///   flowtrig_RunFlow_TeamA    -&gt; "TeamA"
        /// </summary>
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
                    $"RunFlowDispatcher does not know how to route caller message '{callerMessageName}'. " +
                    $"Expected '{_callerMessagePrefix}' or '{_callerMessagePrefix}_<Consumer>'.");
            }

            return suffix.Substring(1);
        }

        /// <summary>
        /// Derives the business-event message name from the caller message name
        /// by convention, so adding a new consumer never requires a plug-in
        /// code change or a new plug-in-type registration - only a new pair of
        /// Custom APIs (see deploy/Deploy-FlowTriggerSolution.ps1). E.g. (for
        /// publisher prefix "flowtrig"):
        ///   flowtrig_RunFlow           -&gt; flowtrig_OnFlowRequested
        ///   flowtrig_RunFlow_TeamA     -&gt; flowtrig_OnFlowRequested_TeamA
        /// </summary>
        internal string ResolveEventMessageName(string callerMessageName)
        {
            var consumerId = ResolveConsumerId(callerMessageName);
            return string.Equals(consumerId, "Default", StringComparison.OrdinalIgnoreCase)
                ? _eventMessagePrefix
                : _eventMessagePrefix + "_" + consumerId;
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
                    $"RunFlowDispatcher could not raise business event '{eventMessageName}'. Confirm the event " +
                    "Custom API and its Catalog Assignment exist for this consumer, and that the worker flow's " +
                    "trigger is enabled. " + ex.Message, ex);
            }
        }

        private string PollForResult(IOrganizationService service, ITracingService tracing, Guid correlationId)
        {
            var deadline = DateTime.UtcNow.Add(PollBudget);

            while (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(PollInterval);

                var query = new QueryExpression(_resultTableLogicalName)
                {
                    ColumnSet = new ColumnSet(_statusField, _messageField),
                    TopCount = 1
                };
                query.Criteria.AddCondition(_correlationIdField, ConditionOperator.Equal, correlationId.ToString());
                query.AddOrder("createdon", OrderType.Descending);

                var results = service.RetrieveMultiple(query);
                if (results.Entities.Count > 0)
                {
                    var row = results.Entities[0];
                    var status = row.GetAttributeValue<string>(_statusField) ?? "Succeeded";
                    var message = row.GetAttributeValue<string>(_messageField) ?? string.Empty;

                    tracing.Trace("RunFlowDispatcher: result row found for correlation {0}, status={1}", correlationId, status);

                    return BuildJson(status, message);
                }
            }

            tracing.Trace("RunFlowDispatcher: poll budget exhausted for correlation {0}", correlationId);
            return BuildJson(
                "Timeout",
                "The flow did not write a result within the allotted time. It may still be running - check the flow's run history.");
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
