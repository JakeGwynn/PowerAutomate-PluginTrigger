using System;
using Microsoft.Xrm.Sdk;

namespace FlowTrigger.Plugins.PerfTest
{
    /// <summary>
    /// PERF-TESTING COPY of ../../plugin/RunFlowMainOperation.cs. Logic is
    /// UNCHANGED from the original - no instrumentation was added here on
    /// purpose. The entire point of measuring "T6 dispatcher exit -&gt;
    /// caller's CompletionTimestamp" (see RunFlowDispatcherTelemetry.cs
    /// remarks) is to see how expensive the real trivial-relay step is; if
    /// this file did its own extra DB I/O or timestamp bookkeeping, that
    /// measurement would no longer describe the actual production
    /// RunFlowMainOperation, it would describe this test harness instead.
    ///
    /// Bound directly as the caller Custom API's Main Operation
    /// implementation (CustomAPI.PluginTypeId), same as the original - not
    /// separately registered as an SdkMessageProcessingStep.
    /// </summary>
    public class RunFlowMainOperationTelemetry : IPlugin
    {
        public void Execute(IServiceProvider serviceProvider)
        {
            if (serviceProvider == null)
            {
                throw new ArgumentNullException(nameof(serviceProvider));
            }

            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
            var tracing = (ITracingService)serviceProvider.GetService(typeof(ITracingService));

            var outputJson = FindSharedVariable(context, RunFlowDispatcherTelemetry.SharedVariablesKey);

            if (outputJson == null)
            {
                tracing.Trace(
                    "RunFlowMainOperationTelemetry: no '{0}' SharedVariable found on this context or its parent - " +
                    "was RunFlowDispatcherTelemetry registered at PreValidation (stage 10) on this message?",
                    RunFlowDispatcherTelemetry.SharedVariablesKey);
                throw new InvalidPluginExecutionException(
                    "RunFlowMainOperationTelemetry could not find the dispatcher's result. Confirm RunFlowDispatcherTelemetry is " +
                    "registered at the PreValidation stage for this Custom API's message.");
            }

            context.OutputParameters["OutputJson"] = outputJson;
        }

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
