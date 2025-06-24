{ lib }:

{
  mkRepoId = url:
    let
      cleaned = lib.removePrefix "https://huggingface.co/" 
                (lib.removePrefix "http://huggingface.co/" 
                (lib.removePrefix "hf:" url));
      parts = lib.splitString "/" cleaned;
    in
      if (builtins.length parts) < 2 then
        throw "Invalid repository URL '${url}'"
      else {
        org = builtins.elemAt parts 0;
        repo = builtins.elemAt parts 1;
        repoId = "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";
      };
}
