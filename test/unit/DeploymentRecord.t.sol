// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit tests for the deployment-record read/write helpers used by the deploy
///         scripts to persist addresses and deploy params into config/deployments/<alias>.json.
/// @dev Forge runs test functions concurrently against one real filesystem, so every
///      test writes its OWN path. The trailing `vm.removeFile` is courtesy, not
///      correctness: a failed assertion reverts before it.
contract DeploymentRecordTest is Test {
  // Written under out/governance/ so the real config/deployments/ records are untouched.
  string internal constant DIR = "out/governance/";

  address internal constant FACTORY = address(0x1111111111111111111111111111111111111111);
  address internal constant RESOLVER = address(0x2222222222222222222222222222222222222222);
  address internal constant VERIFIER = address(0x3333333333333333333333333333333333333333);
  address internal constant FEE_AGGREGATOR = address(0x4444444444444444444444444444444444444444);
  address internal constant ALLOWLIST_ADMIN = address(0x5555555555555555555555555555555555555555);
  address internal constant RMN = address(0x6666666666666666666666666666666666666666);
  address internal constant ALLOWLISTED = address(0x7777777777777777777777777777777777777777);
  address internal constant DEPLOYER = address(0x8888888888888888888888888888888888888888);
  address internal constant SECOND_VERIFIER = address(0x9999999999999999999999999999999999999999);
  bytes4 internal constant VERSION_TAG = bytes4(0x00010001);
  bytes4 internal constant SECOND_TAG = bytes4(0x00010002);
  bytes32 internal constant SALT = bytes32(uint256(0xBEEF));

  RecordReader internal reader;

  function setUp() public {
    vm.createDir("out/governance", true);
    reader = new RecordReader();
  }

  function test_writeRead_roundTripsAddresses() public {
    string memory path = _path("addresses");
    ConfigLib.writeDeploymentByPath(path, _record());

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.aliasName, "testchain");
    assertEq(got.factory, FACTORY);
    assertEq(got.resolver, RESOLVER);
    assertEq(got.verifiers.length, 2, "both verifiers survive the round trip");
    assertEq(got.verifiers[0].versionTag, VERSION_TAG);
    assertEq(got.verifiers[0].addr, VERIFIER);
    assertEq(got.verifiers[1].versionTag, SECOND_TAG);
    assertEq(got.verifiers[1].addr, SECOND_VERIFIER);

    vm.removeFile(path);
  }

  function test_writeRead_roundTripsDeployParams() public {
    string memory path = _path("params");
    Types.Deployment memory written = _record();
    ConfigLib.writeDeploymentByPath(path, written);

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.factoryParams.deployer, DEPLOYER);
    assertEq(got.factoryParams.allowList.length, 1);
    assertEq(got.factoryParams.allowList[0], ALLOWLISTED);
    assertEq(got.factoryParams.encodedArgs, written.factoryParams.encodedArgs);

    assertEq(got.resolverParams.salt, SALT);
    assertEq(got.resolverParams.encodedArgs.length, 0, "resolver takes no constructor args");

    assertEq(got.verifiers[0].feeAggregator, FEE_AGGREGATOR);
    assertEq(got.verifiers[0].allowlistAdmin, ALLOWLIST_ADMIN);
    assertEq(got.verifiers[0].rmn, RMN);
    assertEq(got.verifiers[0].storageLocations.length, 2);
    assertEq(got.verifiers[0].storageLocations[0], "https://agg.one");
    assertEq(got.verifiers[0].storageLocations[1], "https://agg.two");
    assertEq(got.verifiers[0].encodedArgs, written.verifiers[0].encodedArgs);
    assertEq(got.verifiers[1].encodedArgs, written.verifiers[1].encodedArgs, "second entry keeps its own args");

    vm.removeFile(path);
  }

  /// @dev verify.sh picks each verifier's source from this field, so it must survive the
  ///      round trip per entry.
  function test_writeRead_roundTripsContractName() public {
    string memory path = _path("contract-name");
    ConfigLib.writeDeploymentByPath(path, _record());

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.verifiers[0].contractName, "CommitteeVerifier");
    assertEq(got.verifiers[1].contractName, "BpsFeeCommitteeVerifier", "second entry keeps its own implementation");

    vm.removeFile(path);
  }

  /// @dev An unset name is written as the default rather than as "", so the file always
  ///      says what verify.sh will verify against.
  function test_write_unsetContractNameWritesTheDefault() public {
    string memory path = _path("contract-name-unset");
    Types.Deployment memory d = _record();
    d.verifiers[0].contractName = "";
    ConfigLib.writeDeploymentByPath(path, d);

    assertEq(vm.parseJsonString(vm.readFile(path), ".verifiers[0].contract"), "CommitteeVerifier");

    vm.removeFile(path);
  }

  /// @dev Records written before the field existed only ever held a CommitteeVerifier.
  function test_read_entryWithoutContractReadsAsCommitteeVerifier() public {
    string memory path = _path("contract-name-legacy");
    vm.writeFile(path, _rawRecord(string.concat("[", _rawEntry("0x00010001", vm.toString(VERIFIER)), "]")));

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.verifiers[0].contractName, "CommitteeVerifier");

    vm.removeFile(path);
  }

  /// @dev The load-bearing invariant behind recording both forms: `encodedArgs` is what
  ///      verify.sh hands to forge verify-contract, and the plain fields are what the
  ///      deployments page shows. They must describe the same deployment.
  function test_verifierEncodedArgs_decodeToThePlainFields() public {
    string memory path = _path("verifier-encoding");
    ConfigLib.writeDeploymentByPath(path, _record());
    Types.VerifierDeployment memory got = ConfigLib.readDeploymentByPath(path).verifiers[0];

    (DynamicConfigMirror memory dynamicConfig, string[] memory storageLocations, address rmn, bytes4 versionTag) =
      abi.decode(got.encodedArgs, (DynamicConfigMirror, string[], address, bytes4));

    assertEq(dynamicConfig.feeAggregator, got.feeAggregator, "feeAggregator");
    assertEq(dynamicConfig.allowlistAdmin, got.allowlistAdmin, "allowlistAdmin");
    assertEq(rmn, got.rmn, "rmn");
    assertEq(versionTag, got.versionTag, "versionTag");
    assertEq(storageLocations.length, got.storageLocations.length, "storageLocations length");
    for (uint256 i = 0; i < storageLocations.length; ++i) {
      assertEq(storageLocations[i], got.storageLocations[i]);
    }

    vm.removeFile(path);
  }

  function test_factoryEncodedArgs_decodeToThePlainAllowList() public {
    string memory path = _path("factory-encoding");
    ConfigLib.writeDeploymentByPath(path, _record());
    Types.FactoryDeployParams memory got = ConfigLib.readDeploymentByPath(path).factoryParams;

    address[] memory allowList = abi.decode(got.encodedArgs, (address[]));
    assertEq(allowList.length, got.allowList.length);
    assertEq(allowList[0], got.allowList[0]);

    vm.removeFile(path);
  }

  /// @dev A record grows one contract at a time, so a zero address must read back as an
  ///      empty params block rather than as values that look authoritative.
  function test_zeroedBlocks_readBackEmpty() public {
    string memory path = _path("partial");
    Types.Deployment memory d;
    d.aliasName = "testchain";
    d.factory = FACTORY;
    d.factoryParams =
      Types.FactoryDeployParams({deployer: DEPLOYER, allowList: _allowList(), encodedArgs: abi.encode(_allowList())});

    ConfigLib.writeDeploymentByPath(path, d);
    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.factory, FACTORY, "factory recorded");
    assertEq(got.factoryParams.allowList.length, 1);
    assertEq(got.resolver, address(0), "resolver not deployed");
    assertEq(got.resolverParams.salt, bytes32(0), "no resolver params");
    assertEq(got.verifiers.length, 0, "no verifiers recorded yet");

    vm.removeFile(path);
  }

  /// @dev A record whose blocks are not the shape this library writes must fail loudly. The
  ///      danger is the tolerant read: it would return zero addresses, which every
  ///      consumer treats as "nothing deployed here" and reports success on.
  function test_malformedRecord_revertsRatherThanReadingAsUndeployed() public {
    string memory path = _path("malformed");
    vm.writeFile(
      path,
      '{"alias":"testchain",' '"factory":"0x1111111111111111111111111111111111111111",'
      '"resolver":"0x2222222222222222222222222222222222222222",' '"verifiers":[]}'
    );

    // Read through an external call: ConfigLib is an internal library, so its revert
    // shares this frame and expectRevert cannot see it otherwise.
    vm.expectRevert();
    // the expected revert is the assertion; the call returns no usable value
    // forge-lint: disable-next-line(unused-return)
    reader.read(path);

    vm.removeFile(path);
  }

  /// @dev Two writes in one run share Foundry's serializer state; the second must not
  ///      inherit the first record's params.
  function test_secondWrite_doesNotInheritTheFirstRecordsParams() public {
    string memory path = _path("staleness");
    ConfigLib.writeDeploymentByPath(path, _record());

    Types.Deployment memory second;
    second.aliasName = "otherchain";
    second.verifiers = new Types.VerifierDeployment[](1);
    second.verifiers[0].versionTag = SECOND_TAG;
    second.verifiers[0].addr = SECOND_VERIFIER;
    ConfigLib.writeDeploymentByPath(path, second);

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);
    assertEq(got.factory, address(0), "stale factory address leaked");
    assertEq(got.resolver, address(0), "stale resolver address leaked");
    assertEq(got.verifiers.length, 1, "stale verifier entry leaked");
    assertEq(got.verifiers[0].rmn, address(0), "stale verifier params leaked");
    assertEq(got.verifiers[0].storageLocations.length, 0, "stale storageLocations leaked");

    vm.removeFile(path);
  }

  /// @dev An operator whose contracts are live but whose record is missing copies
  ///      `_template.json` and pastes the addresses in. That file must
  ///      read: its `args` blocks hold empty arrays and `"0x"`, which the reader parses as
  ///      soon as an address is non-zero.
  function test_templateWithAddressesFilledIn_reads() public {
    string memory path = _path("hand-authored");
    string memory record = vm.readFile("config/deployments/_template.json");
    record = vm.replace(record, '"alias": ""', '"alias": "testchain"');
    record = vm.replace(record, "0x0000000000000000000000000000000000000000", vm.toString(FACTORY));
    vm.writeFile(path, record);

    Types.Deployment memory got = ConfigLib.readDeploymentByPath(path);

    assertEq(got.aliasName, "testchain");
    assertEq(got.factory, FACTORY, "factory address read");
    assertEq(got.factoryParams.allowList.length, 0, "empty allowList survives the read");
    assertEq(got.factoryParams.encodedArgs.length, 0, '"0x" reads as empty bytes');
    assertEq(got.verifiers.length, 0, "template ships no verifier entries");

    vm.removeFile(path);
  }

  /// @dev Every run deploys from scratch and DeployVerifier writes complete entries, so
  ///      an entry without args is a malformed record and must not read as zeroes.
  function test_verifierEntryWithoutParams_revertsAsMalformed() public {
    string memory path = _path("argless-entry");
    vm.writeFile(
      path, _rawRecord('[{"versionTag":"0x00010001","address":"0x3333333333333333333333333333333333333333"}]')
    );

    vm.expectRevert();
    // the expected revert is the assertion; the call returns no usable value
    // forge-lint: disable-next-line(unused-return)
    reader.read(path);

    vm.removeFile(path);
  }

  function test_readDeploymentOrEmpty_missingReturnsAliasOnly() public view {
    Types.Deployment memory d = ConfigLib.readDeploymentOrEmpty("does-not-exist-xyz");
    assertEq(d.aliasName, "does-not-exist-xyz", "alias set");
    assertEq(d.factory, address(0), "no addresses");
    assertEq(d.resolver, address(0));
    assertEq(d.verifiers.length, 0);
  }

  function test_read_revertsOnDuplicateTag() public {
    _expectReadRevert(
      "dup",
      _rawRecord(
        string.concat(
          "[",
          _rawEntry("0x00010001", "0x3333333333333333333333333333333333333333"),
          ",",
          _rawEntry("0x00010001", "0x4444444444444444444444444444444444444444"),
          "]"
        )
      ),
      "duplicate versionTag"
    );
  }

  function test_read_revertsOnZeroTag() public {
    _expectReadRevert(
      "zero-tag",
      _rawRecord(string.concat("[", _rawEntry("0x00000000", "0x3333333333333333333333333333333333333333"), "]")),
      "is malformed"
    );
  }

  function test_read_revertsOnZeroAddress() public {
    _expectReadRevert(
      "zero-addr",
      _rawRecord(string.concat("[", _rawEntry("0x00010001", "0x0000000000000000000000000000000000000000"), "]")),
      "zero verifier address"
    );
  }

  // --------------------------------------------------------------------------
  //  helpers
  // --------------------------------------------------------------------------
  function _path(
    string memory name
  ) internal pure returns (string memory) {
    return string.concat(DIR, "deploy-", name, ".local.json");
  }

  /// @dev A complete verifier entry with zeroed args, hand-built in the written schema.
  function _rawEntry(
    string memory tag,
    string memory addr
  ) internal pure returns (string memory) {
    return string.concat(
      '{"versionTag":"',
      tag,
      '","address":"',
      addr,
      '",',
      '"args":{"feeAggregator":"0x0000000000000000000000000000000000000000",',
      '"allowlistAdmin":"0x0000000000000000000000000000000000000000",',
      '"storageLocations":[],"rmn":"0x0000000000000000000000000000000000000000"},',
      '"encodedArgs":"0x"}'
    );
  }

  /// @dev A record in the written schema with zeroed factory/resolver blocks (their
  ///      params are skipped on read) and a caller-supplied verifiers array.
  function _rawRecord(
    string memory verifiersJson
  ) internal pure returns (string memory) {
    return string.concat(
      '{"alias":"raw",',
      '"factory":{"address":"0x0000000000000000000000000000000000000000"},',
      '"resolver":{"address":"0x0000000000000000000000000000000000000000"},',
      '"verifiers":',
      verifiersJson,
      "}"
    );
  }

  function _expectReadRevert(
    string memory caseName,
    string memory json,
    string memory reasonFragment
  ) private {
    string memory path = _path(caseName);
    vm.writeFile(path, json);
    try reader.read(path) {
      fail();
    } catch Error(string memory reason) {
      assertTrue(vm.contains(reason, reasonFragment), string.concat("reason names the problem: ", reason));
    }
    vm.removeFile(path);
  }

  function _allowList() internal pure returns (address[] memory allowList) {
    allowList = new address[](1);
    allowList[0] = ALLOWLISTED;
  }

  function _storageLocations() internal pure returns (string[] memory storageLocations) {
    storageLocations = new string[](2);
    storageLocations[0] = "https://agg.one";
    storageLocations[1] = "https://agg.two";
  }

  function _record() internal pure returns (Types.Deployment memory d) {
    d.aliasName = "testchain";
    d.factory = FACTORY;
    d.resolver = RESOLVER;
    d.factoryParams =
      Types.FactoryDeployParams({deployer: DEPLOYER, allowList: _allowList(), encodedArgs: abi.encode(_allowList())});
    d.resolverParams = Types.ResolverDeployParams({salt: SALT, encodedArgs: ""});

    d.verifiers = new Types.VerifierDeployment[](2);
    d.verifiers[0] = _entry(VERSION_TAG, VERIFIER);
    d.verifiers[1] = _entry(SECOND_TAG, SECOND_VERIFIER);
    d.verifiers[1].contractName = "BpsFeeCommitteeVerifier";
  }

  function _entry(
    bytes4 versionTag,
    address addr
  ) internal pure returns (Types.VerifierDeployment memory) {
    return Types.VerifierDeployment({
      versionTag: versionTag,
      addr: addr,
      contractName: "CommitteeVerifier",
      feeAggregator: FEE_AGGREGATOR,
      allowlistAdmin: ALLOWLIST_ADMIN,
      storageLocations: _storageLocations(),
      rmn: RMN,
      encodedArgs: abi.encode(
        DynamicConfigMirror({feeAggregator: FEE_AGGREGATOR, allowlistAdmin: ALLOWLIST_ADMIN}),
        _storageLocations(),
        RMN,
        versionTag
      )
    });
  }

  /// @dev Mirrors CommitteeVerifier.DynamicConfig so this unit test asserts the encoding
  ///      without pulling the Chainlink contract into scope.
  struct DynamicConfigMirror {
    address feeAggregator;
    address allowlistAdmin;
  }
}

/// @notice External seam so `vm.expectRevert` (and try/catch) can observe a revert raised
///         inside an internal library call.
contract RecordReader {
  function read(
    string memory path
  ) external view returns (Types.Deployment memory) {
    return ConfigLib.readDeploymentByPath(path);
  }
}
