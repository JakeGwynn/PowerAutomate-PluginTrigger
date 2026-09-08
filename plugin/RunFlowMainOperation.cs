using System;
using Microsoft.Xrm.Sdk;

namespace FlowTrigger.Plugins
{
    /// <summary>
    /// The trivial "other half" of <see cref="RunFlowDispatcher"/>. This type
    /// is bound directly as the caller Custom API's Main Operation
    /// implementation (CustomAPI.PluginTypeId in
    /// deploy/Deploy-FlowTriggerSolution.ps1) - it is NOT separately
    /// registered as an SdkMessageProcessingStep the way RunFlowDispatcher's
    /// PreValidation step is.
    ///
    /// Why this type exists at all instead of just doing everything in one
    /// plugin: see the architecture note on <see cref="RunFlowDispatcher"/>.
    /// In short, all the real work (raising the business event and polling
    /// for its result) must run at the PreValidation stage, outside the
    /// platform's core operation transaction, so the raised event can
    /// actually be dispatched to a subscribed Power Automate flow while this
    /// request is still in flight. But only the plugin bound as the Main
    /// Operation implementation can reliably set the Custom API's actual
    /// OutputParameters (what a caller's Web API response body reflects) -
    /// so this type's entire job is to read the value RunFlowDispatcher left
    /// behind in SharedVariables and copy it into OutputParameters. It does
    /// no database I/O of its own, so its participation in the enclosing
    /// transaction is irrelevant - there's nothing for that transaction to
    /// hold open, and it returns immediately.
    /// </summary>
    public class RunFlowMainOperation : IPlugin
    {
        public void Execute(IServiceProvider serviceProvider)
        {
            if (serviceProvider == null)
            {
                throw new ArgumentNullException(nameof(serviceProvider));
            }

            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
            var tracing = (ITracingService)serviceProvider.GetService(typeof(ITracingService));

            var outputJson = FindSharedVariable(context, RunFlowDispatcher.SharedVariablesKey);

            if (outputJson == null)
            {
                // Should not happen in normal operation (RunFlowDispatcher's
                // PreValidation step always runs first and always sets this),
                // but fail loudly rather than silently returning an empty
                // response if the two steps ever become mis-registered.
                tracing.Trace(
                    "RunFlowMainOperation: no '{0}' SharedVariable found on this context or its parent - " +
                    "was RunFlowDispatcher registered at PreValidation (stage 10) on this message?",
                    RunFlowDispatcher.SharedVariablesKey);
                throw new InvalidPluginExecutionException(
                    "RunFlowMainOperation could not find the dispatcher's result. Confirm RunFlowDispatcher is " +
                    "registered at the PreValidation stage for this Custom API's message.");
            }

            context.OutputParameters["OutputJson"] = outputJson;
        }

        /// <summary>
        /// Checks the current execution context's SharedVariables first, then
        /// falls back to the parent context's, because different pipeline
        /// configurations may surface the shared variable on either context.
        /// </summary>
        private static string FindSharedVariable(IPluginExecutionContext context, string key)
        {
            if (context.SharedVariables.Contains(key))
            {
                return context.SharedVariables[key] as string;
            }

            var parent = context.ParentContext;
            if (parent != null && parent.SharedVariables.Contains(key))
            {
                return parent.SharedVariables[key] as string;
            }

            return null;
        }
    }
}
