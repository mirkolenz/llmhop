# What the options and the config of the gateway share.
{ config, lib }:
rec {
  util = import ../lib lib;
  llmhop = config.services.llmhop;
  cfg = llmhop.gateway;
  owner = "services.llmhop.gateway";
  workloads = (import ../backends/workload lib).allWorkloads llmhop;
}
