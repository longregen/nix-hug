{ lib }:

{
  # Simple filter function - just apply include/exclude patterns to LFS files
  # Non-LFS files are always included (they're small and come from git)
  applyFilter = filter: files:
    if filter == null then
      files
    else
      let
        # Only filter valid file objects
        validFiles = lib.filter (f: f != null && builtins.isAttrs f && f ? path) files;
        
        # Separate LFS and non-LFS files
        lfsFiles = lib.filter (f: f ? lfs) validFiles;
        nonLfsFiles = lib.filter (f: !(f ? lfs)) validFiles;
        
        # Apply filter
        filteredFiles = 
          if filter ? include then
            # Include LFS files matching any pattern + all non-LFS files
            lib.filter (f: 
              lib.any (pattern: builtins.match pattern f.path != null) filter.include
            ) lfsFiles ++ nonLfsFiles
          else if filter ? exclude then
            # Exclude LFS files matching any pattern + all non-LFS files
            lib.filter (f: 
              !lib.any (pattern: builtins.match pattern f.path != null) filter.exclude
            ) lfsFiles ++ nonLfsFiles
          else if filter ? files then
            # Only specific files (ignores LFS distinction)
            lib.filter (f: 
              lib.elem f.path filter.files
            ) validFiles
          else
            validFiles;
      in
        filteredFiles;
}
