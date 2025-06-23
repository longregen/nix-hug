let
  # Helper to get character at index
  charAt = index: str: builtins.substring index 1 str;
  
  # Convert string to list of byte values (ASCII only)
  stringToBytes = str:
    let
      charToInt = c:
        if c == "\x00" then 0 else if c == "\x01" then 1 else if c == "\x02" then 2 else if c == "\x03" then 3
        else if c == "\x04" then 4 else if c == "\x05" then 5 else if c == "\x06" then 6 else if c == "\x07" then 7
        else if c == "\x08" then 8 else if c == "\x09" then 9 else if c == "\x0a" then 10 else if c == "\x0b" then 11
        else if c == "\x0c" then 12 else if c == "\x0d" then 13 else if c == "\x0e" then 14 else if c == "\x0f" then 15
        else if c == "\x10" then 16 else if c == "\x11" then 17 else if c == "\x12" then 18 else if c == "\x13" then 19
        else if c == "\x14" then 20 else if c == "\x15" then 21 else if c == "\x16" then 22 else if c == "\x17" then 23
        else if c == "\x18" then 24 else if c == "\x19" then 25 else if c == "\x1a" then 26 else if c == "\x1b" then 27
        else if c == "\x1c" then 28 else if c == "\x1d" then 29 else if c == "\x1e" then 30 else if c == "\x1f" then 31
        else if c == " " then 32 else if c == "!" then 33 else if c == "\"" then 34 else if c == "#" then 35
        else if c == "$" then 36 else if c == "%" then 37 else if c == "&" then 38 else if c == "'" then 39
        else if c == "(" then 40 else if c == ")" then 41 else if c == "*" then 42 else if c == "+" then 43
        else if c == "," then 44 else if c == "-" then 45 else if c == "." then 46 else if c == "/" then 47
        else if c == "0" then 48 else if c == "1" then 49 else if c == "2" then 50 else if c == "3" then 51
        else if c == "4" then 52 else if c == "5" then 53 else if c == "6" then 54 else if c == "7" then 55
        else if c == "8" then 56 else if c == "9" then 57 else if c == ":" then 58 else if c == ";" then 59
        else if c == "<" then 60 else if c == "=" then 61 else if c == ">" then 62 else if c == "?" then 63
        else if c == "@" then 64 else if c == "A" then 65 else if c == "B" then 66 else if c == "C" then 67
        else if c == "D" then 68 else if c == "E" then 69 else if c == "F" then 70 else if c == "G" then 71
        else if c == "H" then 72 else if c == "I" then 73 else if c == "J" then 74 else if c == "K" then 75
        else if c == "L" then 76 else if c == "M" then 77 else if c == "N" then 78 else if c == "O" then 79
        else if c == "P" then 80 else if c == "Q" then 81 else if c == "R" then 82 else if c == "S" then 83
        else if c == "T" then 84 else if c == "U" then 85 else if c == "V" then 86 else if c == "W" then 87
        else if c == "X" then 88 else if c == "Y" then 89 else if c == "Z" then 90 else if c == "[" then 91
        else if c == "\\" then 92 else if c == "]" then 93 else if c == "^" then 94 else if c == "_" then 95
        else if c == "`" then 96 else if c == "a" then 97 else if c == "b" then 98 else if c == "c" then 99
        else if c == "d" then 100 else if c == "e" then 101 else if c == "f" then 102 else if c == "g" then 103
        else if c == "h" then 104 else if c == "i" then 105 else if c == "j" then 106 else if c == "k" then 107
        else if c == "l" then 108 else if c == "m" then 109 else if c == "n" then 110 else if c == "o" then 111
        else if c == "p" then 112 else if c == "q" then 113 else if c == "r" then 114 else if c == "s" then 115
        else if c == "t" then 116 else if c == "u" then 117 else if c == "v" then 118 else if c == "w" then 119
        else if c == "x" then 120 else if c == "y" then 121 else if c == "z" then 122 else if c == "{" then 123
        else if c == "|" then 124 else if c == "}" then 125 else if c == "~" then 126 else if c == "\x7f" then 127
        else if c == "\t" then 9 else if c == "\n" then 10 else if c == "\r" then 13
        else builtins.abort "Unsupported character: ${c}";
    in
      builtins.genList (i: charToInt (charAt i str)) (builtins.stringLength str);
  
  # Convert 3 bytes to 4 base64 characters (generic function)
  bytesToBase64Chunk = alphabet: usePadding: bytes:
    let
      # Pad to 3 bytes if needed
      paddedBytes = bytes ++ (builtins.genList (_: 0) (3 - (builtins.length bytes)));
      b1 = builtins.elemAt paddedBytes 0;
      b2 = builtins.elemAt paddedBytes 1;
      b3 = builtins.elemAt paddedBytes 2;
      
      # Convert to 4 6-bit values
      v1 = builtins.bitAnd (b1 / 4) 63;
      v2 = builtins.bitAnd ((b1 * 16) + (b2 / 16)) 63;
      v3 = builtins.bitAnd ((b2 * 4) + (b3 / 64)) 63;
      v4 = builtins.bitAnd b3 63;
      
      # Convert to base64 characters
      c1 = charAt v1 alphabet;
      c2 = charAt v2 alphabet;
      c3 = if (builtins.length bytes) > 1 then charAt v3 alphabet else (if usePadding then "=" else "");
      c4 = if (builtins.length bytes) > 2 then charAt v4 alphabet else (if usePadding then "=" else "");
    in
      c1 + c2 + c3 + c4;
  
  # Split list into chunks of size n
  chunksOf = n: list:
    if (builtins.length list) == 0 then []
    else
      let
        listLen = builtins.length list;
        chunkSize = if n < listLen then n else listLen;
        chunk = builtins.genList (i: builtins.elemAt list i) chunkSize;
        restLen = listLen - n;
        rest = if restLen > 0 then builtins.genList (i: builtins.elemAt list (n + i)) restLen else [];
      in
        [chunk] ++ (chunksOf n rest);
  
  # Generic base64 encode function
  base64EncodeGeneric = alphabet: usePadding: str:
    let
      bytes = stringToBytes str;
      chunks = chunksOf 3 bytes;
      base64Chunks = map (bytesToBase64Chunk alphabet usePadding) chunks;
    in
      builtins.concatStringsSep "" base64Chunks;

  # Standard base64 encoding (RFC 4648) with padding and +/
  standardBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  base64Encode = base64EncodeGeneric standardBase64Alphabet true;

  # URL-safe base64 encoding (RFC 4648) without padding and with -_
  urlSafeBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  base64UrlSafeEncode = base64EncodeGeneric urlSafeBase64Alphabet false;

  # Convert hex string to base64 (generic function)
  hexStringToBase64Generic = alphabet: usePadding: hexStr:
    let
      # Ensure hex string has even length
      paddedHexStr = if (builtins.stringLength hexStr) - ((builtins.stringLength hexStr) / 2) * 2 == 1 then "0" + hexStr else hexStr;
      hexLength = builtins.stringLength paddedHexStr;
      
      # Convert hex string to bytes
      hexPairs = builtins.genList (i: builtins.substring (i * 2) 2 paddedHexStr) (hexLength / 2);
      hexToByte = hexPair:
        let
          c1 = builtins.substring 0 1 hexPair;
          c2 = builtins.substring 1 1 hexPair;
          hexCharToInt = c:
            if c == "0" then 0 else if c == "1" then 1 else if c == "2" then 2 else if c == "3" then 3
            else if c == "4" then 4 else if c == "5" then 5 else if c == "6" then 6 else if c == "7" then 7
            else if c == "8" then 8 else if c == "9" then 9 else if c == "a" then 10 else if c == "b" then 11
            else if c == "c" then 12 else if c == "d" then 13 else if c == "e" then 14 else if c == "f" then 15
            else builtins.abort "Invalid hex character: ${c}";
        in
          (hexCharToInt c1) * 16 + (hexCharToInt c2);
      bytes = map hexToByte hexPairs;
      chunks = chunksOf 3 bytes;
      base64Chunks = map (bytesToBase64Chunk alphabet usePadding) chunks;
    in
      builtins.concatStringsSep "" base64Chunks;

  # Standard hex to base64
  hexStringToBase64 = hexStringToBase64Generic standardBase64Alphabet true;
  
  # URL-safe hex to base64
  hexStringToBase64UrlSafe = hexStringToBase64Generic urlSafeBase64Alphabet false;

in {
  # Standard base64 functions (with padding, +/)
  inherit base64Encode hexStringToBase64;
  
  # URL-safe base64 functions (no padding, -_)
  inherit base64UrlSafeEncode hexStringToBase64UrlSafe;
  
  # Generic functions for custom alphabets
  inherit base64EncodeGeneric hexStringToBase64Generic;
}
