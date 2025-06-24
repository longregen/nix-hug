{ lib }:

{
  applyFilter = filter: files:
    if filter == null then
      files
    else
      let
        validFiles = lib.filter (f: f != null && builtins.isAttrs f && f ? path) files;
        
        lfsFiles = lib.filter (f: f ? lfs) validFiles;
        nonLfsFiles = lib.filter (f: !(f ? lfs)) validFiles;
        
        filteredFiles = 
          if filter ? include then
            lib.filter (f: 
              lib.any (pattern: builtins.match pattern f.path != null) filter.include
            ) lfsFiles ++ nonLfsFiles
          else if filter ? exclude then
            lib.filter (f: 
              !lib.any (pattern: builtins.match pattern f.path != null) filter.exclude
            ) lfsFiles ++ nonLfsFiles
          else if filter ? files then
            lib.filter (f: 
              lib.elem f.path filter.files
            ) validFiles
          else
            validFiles;
      in
        filteredFiles;
}
