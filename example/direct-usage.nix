# Test direct usage without lock file - should show helpful error message
let
  nix-hug = builtins.getFlake "git+file://${toString ../.}";
in
nix-hug.lib.fetchModel {
  url = "ibm-granite/granite-timeseries-patchtst";
  # Missing hash - should give helpful error message
}
