{ lib }:

{
  # Parse repository URL into components
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
  
  # Format file sizes for display
  formatSize = bytes:
    if bytes < 1024 then "${toString bytes} B"
    else if bytes < 1048576 then "${toString (bytes / 1024)} KB"
    else if bytes < 1073741824 then 
      lib.strings.floatToString (bytes * 10 / 1048576 / 10.0) + " MB"
    else 
      lib.strings.floatToString (bytes * 10 / 1073741824 / 10.0) + " GB";
  
  # Generate deterministic variant key from filters
  mkVariantKey = filters:
    if filters == null then "base"
    else builtins.substring 0 8 (
      builtins.hashString "sha256" (builtins.toJSON filters)
    );
}
