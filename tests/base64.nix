{ base64Lib ? import ../base64.nix }:

let
  # Test helper functions
  testCase = name: expected: actual: {
    inherit name expected actual;
    passed = expected == actual;
  };
  
  # Standard base64 test vectors (with padding)
  standardTestVectors = [
    { input = ""; expected = ""; }
    { input = "f"; expected = "Zg=="; }
    { input = "fo"; expected = "Zm8="; }
    { input = "foo"; expected = "Zm9v"; }
    { input = "foob"; expected = "Zm9vYg=="; }
    { input = "fooba"; expected = "Zm9vYmE="; }
    { input = "foobar"; expected = "Zm9vYmFy"; }
    { input = "Hello"; expected = "SGVsbG8="; }
    { input = "Hello World"; expected = "SGVsbG8gV29ybGQ="; }
    { input = "The quick brown fox"; expected = "VGhlIHF1aWNrIGJyb3duIGZveA=="; }
    { input = "0123456789"; expected = "MDEyMzQ1Njc4OQ=="; }
    { input = "!@#$%^&*()"; expected = "IUAjJCVeJiooKQ=="; }
  ];
  
  # URL-safe base64 test vectors (no padding)
  urlSafeTestVectors = [
    { input = ""; expected = ""; }
    { input = "f"; expected = "Zg"; }
    { input = "fo"; expected = "Zm8"; }
    { input = "foo"; expected = "Zm9v"; }
    { input = "foob"; expected = "Zm9vYg"; }
    { input = "fooba"; expected = "Zm9vYmE"; }
    { input = "foobar"; expected = "Zm9vYmFy"; }
    { input = "Hello"; expected = "SGVsbG8"; }
    { input = "Hello World"; expected = "SGVsbG8gV29ybGQ"; }
    { input = "The quick brown fox"; expected = "VGhlIHF1aWNrIGJyb3duIGZveA"; }
    { input = "0123456789"; expected = "MDEyMzQ1Njc4OQ"; }
    { input = "!@#$%^&*()"; expected = "IUAjJCVeJiooKQ"; }
  ];
  
  # Special character test cases (both variants)
  specialCharTestVectors = [
    { input = "\n"; expectedStd = "Cg=="; expectedUrl = "Cg"; }
    { input = "\t"; expectedStd = "CQ=="; expectedUrl = "CQ"; }
    { input = "\r"; expectedStd = "DQ=="; expectedUrl = "DQ"; }
    { input = " "; expectedStd = "IA=="; expectedUrl = "IA"; }
    { input = "a\nb\tc\rd"; expectedStd = "YQpiCWMNZA=="; expectedUrl = "YQpiCWMNZA"; }
  ];
  
  # Binary data test cases (using hex input)
  hexTestVectors = [
    { input = ""; expectedStd = ""; expectedUrl = ""; }
    { input = "00"; expectedStd = "AA=="; expectedUrl = "AA"; }
    { input = "ff"; expectedStd = "/w=="; expectedUrl = "_w"; }
    { input = "0000"; expectedStd = "AAA="; expectedUrl = "AAA"; }
    { input = "ffff"; expectedStd = "//8="; expectedUrl = "__8"; }
    { input = "000000"; expectedStd = "AAAA"; expectedUrl = "AAAA"; }
    { input = "ffffff"; expectedStd = "////"; expectedUrl = "____"; }
    { input = "deadbeef"; expectedStd = "3q2+7w=="; expectedUrl = "3q2-7w"; }
    { input = "cafebabe"; expectedStd = "yv66vg=="; expectedUrl = "yv66vg"; }
    { input = "0123456789abcdef"; expectedStd = "ASNFZ4mrze8="; expectedUrl = "ASNFZ4mrze8"; }
  ];
  
  # Additional hex test cases for edge cases (binary data)
  edgeHexTestVectors = [
    { input = "00"; expectedStd = "AA=="; expectedUrl = "AA"; }
    { input = "01"; expectedStd = "AQ=="; expectedUrl = "AQ"; }
    { input = "7f"; expectedStd = "fw=="; expectedUrl = "fw"; }
    { input = "0000"; expectedStd = "AAA="; expectedUrl = "AAA"; }
    { input = "0001"; expectedStd = "AAE="; expectedUrl = "AAE"; }
    { input = "ffff"; expectedStd = "//8="; expectedUrl = "__8"; }
  ];
  
  # Run standard base64 tests
  runStandardTests = testVectors: description:
    let
      results = map (tv: testCase 
        "${description} (standard): '${tv.input}'" 
        tv.expected 
        (base64Lib.base64Encode tv.input)
      ) testVectors;
    in results;
  
  # Run URL-safe base64 tests
  runUrlSafeTests = testVectors: description:
    let
      results = map (tv: testCase 
        "${description} (URL-safe): '${tv.input}'" 
        tv.expected 
        (base64Lib.base64UrlSafeEncode tv.input)
      ) testVectors;
    in results;
  
  # Run special character tests (both variants)
  runSpecialTests = testVectors: description:
    let
      stdResults = map (tv: testCase 
        "${description} (standard): '${builtins.replaceStrings ["\n" "\t" "\r"] ["\\n" "\\t" "\\r"] tv.input}'" 
        tv.expectedStd 
        (base64Lib.base64Encode tv.input)
      ) testVectors;
      urlResults = map (tv: testCase 
        "${description} (URL-safe): '${builtins.replaceStrings ["\n" "\t" "\r"] ["\\n" "\\t" "\\r"] tv.input}'" 
        tv.expectedUrl 
        (base64Lib.base64UrlSafeEncode tv.input)
      ) testVectors;
    in stdResults ++ urlResults;
  
  # Run hex tests (both variants)
  runHexTests = testVectors: description:
    let
      stdResults = map (tv: testCase 
        "${description} (standard): '${tv.input}'" 
        tv.expectedStd 
        (base64Lib.hexStringToBase64 tv.input)
      ) testVectors;
      urlResults = map (tv: testCase 
        "${description} (URL-safe): '${tv.input}'" 
        tv.expectedUrl 
        (base64Lib.hexStringToBase64UrlSafe tv.input)
      ) testVectors;
    in stdResults ++ urlResults;
  
  # Run edge hex tests (both variants)
  runEdgeHexTests = testVectors: description:
    let
      stdResults = map (tv: testCase 
        "${description} (standard): '${tv.input}'" 
        tv.expectedStd 
        (base64Lib.hexStringToBase64 tv.input)
      ) testVectors;
      urlResults = map (tv: testCase 
        "${description} (URL-safe): '${tv.input}'" 
        tv.expectedUrl 
        (base64Lib.hexStringToBase64UrlSafe tv.input)
      ) testVectors;
    in stdResults ++ urlResults;
  
  # All test results
  allTests = 
    (runStandardTests standardTestVectors "Standard base64") ++
    (runUrlSafeTests urlSafeTestVectors "URL-safe base64") ++
    (runSpecialTests specialCharTestVectors "Special chars") ++
    (runHexTests hexTestVectors "Hex input") ++
    (runEdgeHexTests edgeHexTestVectors "Edge hex cases");
  
  # Test summary
  passedTests = builtins.filter (t: t.passed) allTests;
  failedTests = builtins.filter (t: !t.passed) allTests;
  
  testSummary = {
    total = builtins.length allTests;
    passed = builtins.length passedTests;
    failed = builtins.length failedTests;
    success = (builtins.length failedTests) == 0;
  };
  
  # Format test results for display
  formatTest = test: 
    if test.passed 
    then "✅ ${test.name}"
    else "❌ ${test.name}\n   Expected: ${test.expected}\n   Actual:   ${test.actual}";
  
  # Generate test report
  testReport = 
    let
      header = "Base64 Test Results\n" + 
               "==================\n" +
               "Total: ${toString testSummary.total}, " +
               "Passed: ${toString testSummary.passed}, " +
               "Failed: ${toString testSummary.failed}\n\n";
      
      testResults = builtins.concatStringsSep "\n" (map formatTest allTests);
      
      footer = if testSummary.success 
               then "\n🎉 All tests passed!"
               else "\n💥 Some tests failed!";
    in
      header + testResults + footer;

  # Performance test - encode increasingly large strings
  performanceTests = 
    let
      # Generate test strings of different sizes
      generateString = size: char: 
        builtins.concatStringsSep "" (builtins.genList (_: char) size);
      
      sizes = [1 10 100 1000];
      perfResults = map (size: 
        let
          testStr = generateString size "a";
          stdResult = base64Lib.base64Encode testStr;
          urlResult = base64Lib.base64UrlSafeEncode testStr;
        in {
          size = size;
          inputLength = builtins.stringLength testStr;
          stdOutputLength = builtins.stringLength stdResult;
          urlOutputLength = builtins.stringLength urlResult;
          # Basic validation - base64 output should be ~4/3 the input size
          expectedLength = ((size + 2) / 3) * 4;
          stdLengthCorrect = (builtins.stringLength stdResult) == (((size + 2) / 3) * 4);
          # URL-safe might be shorter due to no padding
          urlLengthValid = (builtins.stringLength urlResult) <= (((size + 2) / 3) * 4);
        }
      ) sizes;
    in perfResults;

in {
  # Main test results
  inherit testSummary allTests passedTests failedTests testReport;
  
  # Additional test data
  inherit performanceTests;
  
  # Test functions for reuse
  inherit testCase runStandardTests runUrlSafeTests;
  
  # Test vectors for external use
  testVectors = {
    inherit standardTestVectors urlSafeTestVectors specialCharTestVectors hexTestVectors edgeHexTestVectors;
  };
  
  # Assertion for flake check - pure evaluation
  assertion = 
    if testSummary.success 
    then true
    else builtins.abort "Base64 tests failed!\n${testReport}";
}
