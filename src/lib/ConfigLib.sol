// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// vm.serializeX accumulates into the object; only the final call returns the JSON.
// forge-lint: disable-start(unused-return)

import {Types} from "./Types.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @title ConfigLib
/// @notice Loads config-as-data JSON from `config/` into typed structs.
/// @dev Fields are read one-by-one (rather than abi.decode of a whole object) so
///      the loader is robust to JSON key ordering and to fields being added later.
///      Chain selectors are stored as JSON strings and parsed here, because they
///      exceed the 2^53 safe-integer range of most JSON tooling.
library ConfigLib {
  Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  string private constant CHAINS_DIR = "config/chains/";
  string private constant LANES_DIR = "config/operator/lanes/";
  string private constant OPERATOR_DIR = "config/operator/chains/";
  string private constant DEPLOYMENTS_DIR = "config/deployments/";
  string private constant OPERATOR_PATH = "config/operator.json";
  /// @dev The implementation a verifier record names when it names none.
  string internal constant DEFAULT_VERIFIER_CONTRACT = "CommitteeVerifier";

  string internal constant BARE_VERIFIER_TARGET_ERROR =
    "ConfigLib: target 'verifier' needs a versionTag - use verifier:<versionTag> (e.g. verifier:0x00010001)";

  // --------------------------------------------------------------------------
  //  config/operator.json (the repo-wide operator file)
  // --------------------------------------------------------------------------
  /// @notice Every versionTag this repo uses, from config/operator.json. Tags are
  ///         CROSS-CHAIN identities (a lane's tag must match on both endpoints), so the
  ///         catalog is repo-wide, not per chain: one spelling everywhere.
  function readVersionTags() internal view returns (bytes4[] memory tags) {
    require(vm.exists(OPERATOR_PATH), string.concat("ConfigLib: missing ", OPERATOR_PATH));
    string memory json = vm.readFile(OPERATOR_PATH);
    uint256 count = 0;
    while (vm.keyExistsJson(json, string.concat(".versionTags[", vm.toString(count), "]"))) {
      ++count;
    }
    tags = new bytes4[](count);
    for (uint256 i = 0; i < count; ++i) {
      bytes4 tag = _parseVersionTag(json, string.concat(".versionTags[", vm.toString(i), "].tag"), OPERATOR_PATH);
      for (uint256 j = 0; j < i; ++j) {
        require(
          tags[j] != tag, string.concat("ConfigLib: duplicate versionTag ", tagToString(tag), " in ", OPERATOR_PATH)
        );
      }
      tags[i] = tag;
    }
  }

  /// @notice The CREATE2 salt the resolver uses on every chain, from config/operator.json.
  ///         One repo-wide value: the resolver lands on the same address everywhere only
  ///         if the salt is identical.
  function readResolverSalt() internal view returns (bytes32) {
    return readResolverSaltByPath(OPERATOR_PATH);
  }

  /// @dev A zero salt is the example file's unfilled state; every unfilled fork would
  ///      deploy to the same address, so it is rejected at load.
  function readResolverSaltByPath(
    string memory path
  ) internal view returns (bytes32 salt) {
    require(vm.exists(path), string.concat("ConfigLib: missing ", path));
    salt = vm.parseJsonBytes32(vm.readFile(path), ".resolverSalt");
    require(
      salt != bytes32(0),
      string.concat("ConfigLib: resolverSalt in ", path, " is zero - set the repo-wide CREATE2 salt")
    );
  }

  /// @dev Parses a versionTag field and enforces the documented scheme: 2 bytes operator
  ///      id + 2 bytes version, both halves non-zero.
  function _parseVersionTag(
    string memory json,
    string memory key,
    string memory source
  ) private pure returns (bytes4 tag) {
    tag = _parseBytes4(json, key);
    // truncating to 'bytes2' is deliberate: each half of the tag is inspected separately
    // forge-lint: disable-next-item(unsafe-typecast)
    bool wellFormed = bytes2(tag) != bytes2(0) && bytes2(tag << 16) != bytes2(0);
    require(
      wellFormed,
      string.concat(
        "ConfigLib: versionTag ",
        tagToString(tag),
        " in ",
        source,
        " is malformed - scheme is 2-byte operator id + 2-byte version, both non-zero"
      )
    );
  }

  /// @notice Reverts unless `tag` is catalogued. Applied where a HUMAN introduces a tag
  ///         (the DeployVerifier argument, lane files); machine-written records are
  ///         cross-checked against the chain by DriftCheck instead.
  function requireKnownTag(
    bytes4 tag,
    string memory context
  ) internal view {
    bytes4[] memory tags = readVersionTags();
    for (uint256 i = 0; i < tags.length; ++i) {
      if (tags[i] == tag) return;
    }
    revert(
      string.concat(
        "ConfigLib: versionTag ",
        tagToString(tag),
        " (",
        context,
        ") is not catalogued in ",
        OPERATOR_PATH,
        " - add it there first"
      )
    );
  }

  // --------------------------------------------------------------------------
  //  chains
  // --------------------------------------------------------------------------
  function chainPath(
    string memory aliasName
  ) internal pure returns (string memory) {
    return string.concat(CHAINS_DIR, aliasName, ".json");
  }

  function readChain(
    string memory aliasName
  ) internal view returns (Types.ChainConfig memory) {
    return readChainByPath(chainPath(aliasName));
  }

  /// @notice Chain config if the file exists, else an empty struct (`chainId == 0`).
  /// @dev For callers that must tolerate an alias with no chain file, e.g. a test scope.
  function readChainOrEmpty(
    string memory aliasName
  ) internal view returns (Types.ChainConfig memory chainConfig) {
    string memory path = chainPath(aliasName);
    if (vm.exists(path)) return readChainByPath(path);
  }

  /// @dev The file is Chainlink's synced reference, so its key set is closed: a key the
  ///      sync does not own would be operator data in the wrong file.
  function readChainByPath(
    string memory path
  ) internal view returns (Types.ChainConfig memory chainConfig) {
    string memory json = vm.readFile(path);
    _requireChainKeys(json, path);
    chainConfig.aliasName = vm.parseJsonString(json, ".alias");
    chainConfig.chainId = vm.parseJsonUint(json, ".chainId");
    chainConfig.chainSelector = _toUint64(vm.parseUint(vm.parseJsonString(json, ".chainSelector")), ".chainSelector");
    chainConfig.rmn = vm.parseJsonAddress(json, ".rmn");
    chainConfig.router = vm.parseJsonAddress(json, ".router");
    // [] is legal: fee scripts are a logged no-op on a chain with no fee tokens.
    chainConfig.feeTokens = vm.parseJsonAddressArray(json, ".feeTokens");
  }

  function _requireChainKeys(
    string memory json,
    string memory path
  ) private pure {
    string[] memory keys = vm.parseJsonKeys(json, ".");
    for (uint256 i = 0; i < keys.length; ++i) {
      string memory k = keys[i];
      bool known = _stringsEqual(k, "alias") || _stringsEqual(k, "chainId") || _stringsEqual(k, "chainSelector")
        || _stringsEqual(k, "router") || _stringsEqual(k, "rmn") || _stringsEqual(k, "feeTokens")
        || _stringsEqual(k, "explorerAddressPath");
      require(
        known,
        string.concat(
          "ConfigLib: ",
          path,
          " has unknown key '",
          k,
          "' - keys are alias, chainId, chainSelector, router, rmn, feeTokens, explorerAddressPath"
        )
      );
    }
  }

  /// @dev Typed block, so the FinalityCodec encoding is generated rather than typed by hand.
  ///      A misspelt key is rejected because it would otherwise read as full finality only.
  function _parseAllowedFinality(
    string memory json,
    string memory key,
    string memory path
  ) private view returns (Types.AllowedFinality memory finality) {
    require(vm.keyExistsJson(json, key), string.concat("ConfigLib: ", path, " has no ", key));
    string[] memory keys = vm.parseJsonKeys(json, key);
    for (uint256 i = 0; i < keys.length; ++i) {
      require(
        _stringsEqual(keys[i], "allowSafeTag") || _stringsEqual(keys[i], "minBlockDepth"),
        string.concat(
          "ConfigLib: allowedFinality in ",
          path,
          " has unknown key '",
          keys[i],
          "' - keys are allowSafeTag, minBlockDepth"
        )
      );
    }
    if (vm.keyExistsJson(json, string.concat(key, ".allowSafeTag"))) {
      finality.allowSafeTag = vm.parseJsonBool(json, string.concat(key, ".allowSafeTag"));
    }
    if (vm.keyExistsJson(json, string.concat(key, ".minBlockDepth"))) {
      uint256 depth = vm.parseJsonUint(json, string.concat(key, ".minBlockDepth"));
      require(
        depth >= 1 && depth <= FinalityCodec.MAX_BLOCK_DEPTH,
        string.concat(
          "ConfigLib: allowedFinality.minBlockDepth in ",
          path,
          " must be 1..65535 - omit it to allow full finality only"
        )
      );
      // casting to 'uint16' is safe because the require above bounds `depth`
      // forge-lint: disable-next-line(unsafe-typecast)
      finality.minBlockDepth = uint16(depth);
    }
  }

  /// @notice Fail-fast chain-identity preflight: the named chain config must exist,
  ///         name itself consistently, and — when an RPC backs the run — match the
  ///         connected network. Call before deployment lookup, reads, or staging.
  /// @dev A valid config against the wrong RPC can pass every other check, so only the
  ///      connected network's own chainid settles which chain a run is acting on.
  function assertChain(
    string memory aliasName
  ) internal view {
    string memory path = chainPath(aliasName);
    require(vm.exists(path), string.concat("ConfigLib: no chain config at ", path));
    assertChainMatches(readChainByPath(path), aliasName);
  }

  /// @dev Split from assertChain for callers that already loaded the config (and tests).
  function assertChainMatches(
    Types.ChainConfig memory chainConfig,
    string memory aliasName
  ) internal view {
    require(
      _stringsEqual(chainConfig.aliasName, aliasName),
      string.concat("ConfigLib: ", chainPath(aliasName), " declares alias '", chainConfig.aliasName, "'")
    );
    require(chainConfig.chainId != 0, string.concat("ConfigLib: ", chainPath(aliasName), " has no chainId"));
    // Every script requires a live RPC (preflights and batch gating read chain state).
    // Without --rpc-url forge runs at 31337, so for a config expecting another chain an
    // unexpected 31337 almost always means the flag is missing — fail with that hint.
    // A config genuinely FOR 31337 (a local anvil chain) is compared like any other.
    require(
      block.chainid != 31337 || chainConfig.chainId == 31337,
      string.concat(
        "ConfigLib: chainid is 31337 but ",
        aliasName,
        " is chain ",
        vm.toString(chainConfig.chainId),
        " - no --rpc-url passed?"
      )
    );
    require(
      block.chainid == chainConfig.chainId,
      string.concat(
        "ConfigLib: connected to chain ",
        vm.toString(block.chainid),
        " but ",
        aliasName,
        " is chain ",
        vm.toString(chainConfig.chainId)
      )
    );
  }

  // --------------------------------------------------------------------------
  //  lanes
  // --------------------------------------------------------------------------
  function lanePath(
    string memory laneName
  ) internal pure returns (string memory) {
    return string.concat(LANES_DIR, laneName, ".json");
  }

  /// @notice Loads one lane by name.
  /// @dev The filename and the `name` field must agree. A mismatch is a config error, not
  ///      a lookup miss, so it fails with that reason rather than "no such lane".
  function readLane(
    string memory laneName
  ) internal view returns (Types.LaneConfig memory lane) {
    lane = readLaneByPath(lanePath(laneName));
    require(
      _stringsEqual(lane.name, laneName),
      string.concat("ConfigLib: ", lanePath(laneName), " declares name '", lane.name, "'")
    );
  }

  /// @notice Returns the file paths of every real lane config (skips `_template`
  ///         and `*.example.json`). Feed each path to `readLaneByPath`.
  /// @dev For callers that need "every lane touching chain X" — they filter on
  ///      `lane.source`/`lane.dest`. To fetch a single known lane, use `readLane`.
  /// @dev Sorted before returning. `vm.readDir` order is filesystem-dependent, and the
  ///      lane-iterating scripts stage every lane into ONE Safe batch, so unsorted paths
  ///      make the generated JSON byte-differ between machines and defeat batch diffing.
  function listLanes() internal view returns (string[] memory paths) {
    Vm.DirEntry[] memory entries = vm.readDir(LANES_DIR);
    string[] memory buf = new string[](entries.length);
    uint256 n = 0;
    for (uint256 i = 0; i < entries.length; ++i) {
      string memory p = entries[i].path;
      if (_hasSuffix(p, ".json") && !_contains(p, "_template") && !_contains(p, ".example.")) {
        buf[n++] = p;
      }
    }

    paths = new string[](n);
    for (uint256 i = 0; i < n; ++i) {
      paths[i] = buf[i];
    }

    sortPaths(paths);
  }

  /// @notice Sorts byte-wise lexicographically, in place. Insertion sort: the input is a
  ///         directory listing, so n is small.
  function sortPaths(
    string[] memory paths
  ) internal pure {
    for (uint256 i = 1; i < paths.length; ++i) {
      string memory key = paths[i];
      uint256 j = i;
      while (j > 0 && _stringLessThan(key, paths[j - 1])) {
        paths[j] = paths[j - 1];
        --j;
      }
      paths[j] = key;
    }
  }

  /// @notice Every lane in `config/operator/lanes/`, parsed.
  function readLanes() internal view returns (Types.LaneConfig[] memory lanes) {
    string[] memory paths = listLanes();
    lanes = new Types.LaneConfig[](paths.length);
    for (uint256 i = 0; i < paths.length; ++i) {
      lanes[i] = readLaneByPath(paths[i]);
    }
  }

  /// @notice The committee that signs messages leaving `lane`'s source chain under the
  ///         tag the lane pins, from that chain's operator file.
  /// @dev The one accessor for it. Declared once on the source, so two destinations of
  ///      the same source and tag cannot disagree about the set.
  function committeeFor(
    Types.LaneConfig memory lane
  ) internal view returns (Types.SignatureConfig memory) {
    return verifierConfigByTag(readOperator(lane.source.aliasName), lane.versionTag).signatureConfig;
  }

  /// @notice Every lane paired with its source's committee, for the scripts that need both.
  function readLaneCommittees() internal view returns (Types.LaneCommittee[] memory paired) {
    Types.LaneConfig[] memory lanes = readLanes();
    paired = new Types.LaneCommittee[](lanes.length);
    for (uint256 i = 0; i < lanes.length; ++i) {
      paired[i] = Types.LaneCommittee({lane: lanes[i], committee: committeeFor(lanes[i])});
    }
  }

  function readLaneByPath(
    string memory path
  ) internal view returns (Types.LaneConfig memory lane) {
    string memory json = vm.readFile(path);
    lane.name = vm.parseJsonString(json, ".name");

    lane.source.aliasName = vm.parseJsonString(json, ".source.alias");
    lane.source.chainSelector =
      _toUint64(vm.parseUint(vm.parseJsonString(json, ".source.chainSelector")), ".source.chainSelector");
    lane.dest.aliasName = vm.parseJsonString(json, ".dest.alias");
    lane.dest.chainSelector =
      _toUint64(vm.parseUint(vm.parseJsonString(json, ".dest.chainSelector")), ".dest.chainSelector");

    // A lane from a chain to itself is never valid, whichever field says so.
    require(
      !_stringsEqual(lane.source.aliasName, lane.dest.aliasName),
      string.concat("ConfigLib: lane ", lane.name, " has the same chain on both ends: ", lane.source.aliasName)
    );
    require(
      lane.source.chainSelector != lane.dest.chainSelector,
      string.concat("ConfigLib: lane ", lane.name, " has the same chainSelector on both ends")
    );

    // Mandatory: the lane pins the verifier serving it (both legs — the contract forces
    // source tag == dest tag).
    require(
      vm.keyExistsJson(json, ".versionTag"),
      string.concat("ConfigLib: lane ", lane.name, " has no versionTag - add \"versionTag\": \"0x00010001\" (bytes4)")
    );
    lane.versionTag = _parseVersionTag(json, ".versionTag", path);
    requireKnownTag(lane.versionTag, string.concat("lane ", lane.name));

    // Optional override: absent inherits the SOURCE chain's synced router; an explicit
    // 0x0 pauses the lane. An inherited zero means the chain was never synced - error.
    if (vm.keyExistsJson(json, ".remoteChainConfig.router")) {
      lane.remote.router = vm.parseJsonAddress(json, ".remoteChainConfig.router");
    } else {
      lane.remote.router = readChain(lane.source.aliasName).router;
      require(
        lane.remote.router != address(0),
        string.concat(
          "ConfigLib: lane ",
          lane.name,
          " inherits its router, but chains/",
          lane.source.aliasName,
          ".json has none - run sync-ccip-config.sh sync ",
          lane.source.aliasName
        )
      );
    }
    lane.remote.feeUSDCents =
      _toUint16(vm.parseJsonUint(json, ".remoteChainConfig.feeUSDCents"), ".remoteChainConfig.feeUSDCents");
    lane.remote.gasForVerification = _toUint32(
      vm.parseJsonUint(json, ".remoteChainConfig.gasForVerification"), ".remoteChainConfig.gasForVerification"
    );
    lane.remote.payloadSizeBytes =
      _toUint16(vm.parseJsonUint(json, ".remoteChainConfig.payloadSizeBytes"), ".remoteChainConfig.payloadSizeBytes");

    lane.allowlist.allowlistEnabled = vm.parseJsonBool(json, ".allowlist.allowlistEnabled");
    lane.allowlist.allowedSenders = vm.parseJsonAddressArray(json, ".allowlist.allowedSenders");
  }

  // --------------------------------------------------------------------------
  //  operator (per chain)
  // --------------------------------------------------------------------------
  function operatorPath(
    string memory aliasName
  ) internal pure returns (string memory) {
    return string.concat(OPERATOR_DIR, aliasName, ".json");
  }

  function readOperator(
    string memory aliasName
  ) internal view returns (Types.OperatorConfig memory) {
    return readOperatorByPath(operatorPath(aliasName));
  }

  /// @notice Operator config, or a zeroed struct if the file does not exist. Lets optional
  ///         steps (e.g. factory ownership handover) proceed without one.
  function readOperatorOrEmpty(
    string memory aliasName
  ) internal view returns (Types.OperatorConfig memory operator) {
    string memory path = operatorPath(aliasName);
    if (vm.exists(path)) return readOperatorByPath(path);
    operator.aliasName = aliasName;
  }

  function readOperatorByPath(
    string memory path
  ) internal view returns (Types.OperatorConfig memory operator) {
    string memory json = vm.readFile(path);
    operator.aliasName = vm.parseJsonString(json, ".alias");

    // Absent array == no verifiers declared yet (factory-only chains).
    uint256 count = 0;
    while (vm.keyExistsJson(json, _verifierConfigKey(count, ""))) {
      ++count;
    }
    operator.verifiers = new Types.VerifierConfig[](count);
    for (uint256 i = 0; i < count; ++i) {
      bytes4 tag = _parseVersionTag(json, _verifierConfigKey(i, ".versionTag"), path);
      for (uint256 j = 0; j < i; ++j) {
        require(
          operator.verifiers[j].versionTag != tag,
          string.concat("ConfigLib: duplicate versionTag ", tagToString(tag), " in ", path)
        );
      }
      operator.verifiers[i].versionTag = tag;
      operator.verifiers[i].allowedFinality =
        _parseAllowedFinality(json, _verifierConfigKey(i, ".allowedFinality"), path);
      operator.verifiers[i].storageLocations = vm.parseJsonStringArray(json, _verifierConfigKey(i, ".storageLocations"));
      operator.verifiers[i].signatureConfig = _parseSignatureConfig(json, _verifierConfigKey(i, ".signatureConfig"));
      operator.verifiers[i].roles = Types.VerifierRoles({
        owner: vm.parseJsonAddress(json, _verifierConfigKey(i, ".roles.owner")),
        storageLocationsAdmin: vm.parseJsonAddress(json, _verifierConfigKey(i, ".roles.storageLocationsAdmin")),
        allowlistAdmin: vm.parseJsonAddress(json, _verifierConfigKey(i, ".roles.allowlistAdmin")),
        feeAggregator: vm.parseJsonAddress(json, _verifierConfigKey(i, ".roles.feeAggregator"))
      });
    }

    operator.resolver.roles.owner = vm.parseJsonAddress(json, ".resolver.roles.owner");
    operator.resolver.roles.feeAggregator = vm.parseJsonAddress(json, ".resolver.roles.feeAggregator");
    operator.factory.roles.owner = vm.parseJsonAddress(json, ".factory.roles.owner");
    operator.factory.roles.allowlist = vm.parseJsonAddressArray(json, ".factory.roles.allowlist");
    for (uint256 i = 0; i < operator.factory.roles.allowlist.length; ++i) {
      require(
        operator.factory.roles.allowlist[i] != address(0),
        string.concat("ConfigLib: zero address in factory.allowlist in ", path)
      );
    }

    // Absent array == no price adapters declared (chains without a bps verifier).
    count = 0;
    while (vm.keyExistsJson(json, _adapterConfigKey(count, ""))) {
      ++count;
    }
    operator.priceAdapters = new Types.PriceAdapterConfig[](count);
    for (uint256 i = 0; i < count; ++i) {
      Types.PriceAdapterConfig memory a = _parsePriceAdapterConfig(json, _adapterConfigKey(i, ""), path);
      for (uint256 j = 0; j < i; ++j) {
        require(
          operator.priceAdapters[j].token != a.token,
          string.concat("ConfigLib: duplicate priceAdapters token ", vm.toString(a.token), " in ", path)
        );
      }
      operator.priceAdapters[i] = a;
    }
  }

  function _adapterConfigKey(
    uint256 index,
    string memory field
  ) private pure returns (string memory) {
    return string.concat(".priceAdapters[", vm.toString(index), "]", field);
  }

  string internal constant L1_PRICE_ADAPTER = "WstETHUSDPriceAdapter";
  string internal constant L2_PRICE_ADAPTER = "WstETHUSDL2PriceAdapter";

  /// @dev One declared adapter. Strict both ways: every key its `contract` takes must be
  ///      present (a missing feed must not read as address(0)), and any other key is
  ///      rejected (an L2-only key on an L1 adapter is a mistake, not a no-op).
  function _parsePriceAdapterConfig(
    string memory json,
    string memory key,
    string memory path
  ) private view returns (Types.PriceAdapterConfig memory a) {
    a.contractName = vm.parseJsonString(json, string.concat(key, ".contract"));
    bool isL2 = _stringsEqual(a.contractName, L2_PRICE_ADAPTER);
    require(
      isL2 || _stringsEqual(a.contractName, L1_PRICE_ADAPTER),
      string.concat(
        "ConfigLib: ",
        key,
        ".contract '",
        a.contractName,
        "' in ",
        path,
        " - must be ",
        L1_PRICE_ADAPTER,
        " or ",
        L2_PRICE_ADAPTER
      )
    );

    string[] memory keys = vm.parseJsonKeys(json, key);
    for (uint256 i = 0; i < keys.length; ++i) {
      string memory k = keys[i];
      bool common = _stringsEqual(k, "contract") || _stringsEqual(k, "token") || _stringsEqual(k, "usdFeed")
        || _stringsEqual(k, "usdMaxStaleness");
      bool l2Only = _stringsEqual(k, "rateFeed") || _stringsEqual(k, "rateMaxStaleness")
        || _stringsEqual(k, "sequencerUptimeFeed") || _stringsEqual(k, "gracePeriod");
      require(
        common || (isL2 && l2Only),
        string.concat("ConfigLib: unknown key '", k, "' in ", key, " (", a.contractName, ") in ", path)
      );
    }

    a.token = _requiredAddress(json, key, "token", path);
    a.usdFeed = _requiredAddress(json, key, "usdFeed", path);
    a.usdMaxStaleness = _requiredUint(json, key, "usdMaxStaleness", path);
    if (isL2) {
      a.rateFeed = _requiredAddress(json, key, "rateFeed", path);
      a.rateMaxStaleness = _requiredUint(json, key, "rateMaxStaleness", path);
      a.sequencerUptimeFeed = _requiredAddress(json, key, "sequencerUptimeFeed", path);
      a.gracePeriod = _requiredUint(json, key, "gracePeriod", path);
    }
  }

  function _requiredAddress(
    string memory json,
    string memory key,
    string memory field,
    string memory path
  ) private view returns (address value) {
    string memory full = string.concat(key, ".", field);
    require(vm.keyExistsJson(json, full), string.concat("ConfigLib: missing ", full, " in ", path));
    value = vm.parseJsonAddress(json, full);
    require(value != address(0), string.concat("ConfigLib: zero address at ", full, " in ", path));
  }

  function _requiredUint(
    string memory json,
    string memory key,
    string memory field,
    string memory path
  ) private view returns (uint256) {
    string memory full = string.concat(key, ".", field);
    require(vm.keyExistsJson(json, full), string.concat("ConfigLib: missing ", full, " in ", path));
    return vm.parseJsonUint(json, full);
  }

  /// @notice The adapter declared for `token`. Reverts when none is: the declaration is
  ///         intent and precedes the deploy, so write it first.
  function priceAdapterConfigByToken(
    Types.OperatorConfig memory operator,
    address token
  ) internal pure returns (Types.PriceAdapterConfig memory) {
    for (uint256 i = 0; i < operator.priceAdapters.length; ++i) {
      if (operator.priceAdapters[i].token == token) return operator.priceAdapters[i];
    }
    revert(
      string.concat(
        "ConfigLib: no priceAdapters entry for token ",
        vm.toString(token),
        " in ",
        operatorPath(operator.aliasName),
        " - declare it before deploying"
      )
    );
  }

  function _parseSignatureConfig(
    string memory json,
    string memory key
  ) private pure returns (Types.SignatureConfig memory config) {
    config.threshold = _toUint8(vm.parseJsonUint(json, string.concat(key, ".threshold")), key);
    config.signers = vm.parseJsonAddressArray(json, string.concat(key, ".signers"));
  }

  function _verifierConfigKey(
    uint256 index,
    string memory field
  ) private pure returns (string memory) {
    return string.concat(".verifiers[", vm.toString(index), "]", field);
  }

  /// @notice Everything declared for the verifier carrying `tag`: its finality, storage
  ///         locations, committee and role holders. Reverts when that tag has no entry —
  ///         the declaration is intent and precedes the deploy, so write it first.
  function verifierConfigByTag(
    Types.OperatorConfig memory operator,
    bytes4 tag
  ) internal pure returns (Types.VerifierConfig memory) {
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      if (operator.verifiers[i].versionTag == tag) return operator.verifiers[i];
    }
    revert(
      string.concat(
        "ConfigLib: no verifiers entry for versionTag ",
        tagToString(tag),
        " in config/operator/chains/",
        operator.aliasName,
        ".json - declare that verifier first"
      )
    );
  }

  function hasVerifierConfigTag(
    Types.OperatorConfig memory operator,
    bytes4 tag
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < operator.verifiers.length; ++i) {
      if (operator.verifiers[i].versionTag == tag) return true;
    }
    return false;
  }

  // --------------------------------------------------------------------------
  //  target resolution ("verifier:<versionTag>" | "resolver" | "factory")
  // --------------------------------------------------------------------------
  /// @notice Maps a target name to its address in the deployment record.
  /// @dev A verifier is always addressed by versionTag: `verifier:0x00010001`. A bare
  ///      `verifier` is rejected — several verifiers can be live at once, and nothing
  ///      may silently pick one.
  function targetAddress(
    Types.Deployment memory deployment,
    string memory target
  ) internal pure returns (address) {
    if (_stringsEqual(target, "verifier")) revert(BARE_VERIFIER_TARGET_ERROR);
    if (_hasPrefix(target, "verifier:")) return verifierByTag(deployment, _tagSuffix(target));
    if (_stringsEqual(target, "resolver")) return deployment.resolver;
    if (_stringsEqual(target, "factory")) return deployment.factory;
    revert(_unknownTarget(target));
  }

  /// @notice Maps a target name to the owner declared for it in `config/operator/chains/<alias>.json`.
  /// @dev Role holders are per verifier; `verifier:<tag>` selects that verifier's
  ///      owner (same grammar as `targetAddress`).
  function targetOwner(
    Types.OperatorConfig memory operator,
    string memory target
  ) internal pure returns (address) {
    if (_stringsEqual(target, "verifier")) revert(BARE_VERIFIER_TARGET_ERROR);
    if (_hasPrefix(target, "verifier:")) return verifierConfigByTag(operator, _tagSuffix(target)).roles.owner;
    if (_stringsEqual(target, "resolver")) return operator.resolver.roles.owner;
    if (_stringsEqual(target, "factory")) return operator.factory.roles.owner;
    revert(_unknownTarget(target));
  }

  function _unknownTarget(
    string memory target
  ) private pure returns (string memory) {
    return string.concat("ConfigLib: unknown target '", target, "' (expected verifier:<versionTag>|resolver|factory)");
  }

  /// @dev Parses the bytes4 after "verifier:", e.g. "verifier:0x00010001".
  function _tagSuffix(
    string memory target
  ) private pure returns (bytes4) {
    bytes memory targetBytes = bytes(target);
    bytes memory suffix = new bytes(targetBytes.length - 9); // len("verifier:") == 9
    for (uint256 i = 0; i < suffix.length; ++i) {
      suffix[i] = targetBytes[i + 9];
    }
    bytes memory raw = vm.parseBytes(string(suffix));
    require(raw.length == 4, string.concat("ConfigLib: '", target, "' must carry a 4-byte hex versionTag"));
    return _toBytes4(raw);
  }

  function _stringsEqual(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    return keccak256(bytes(left)) == keccak256(bytes(right));
  }

  // --------------------------------------------------------------------------
  //  deployments (addresses + deploy params; written by the deploy scripts)
  // --------------------------------------------------------------------------
  function deploymentPath(
    string memory aliasName
  ) internal pure returns (string memory) {
    return string.concat(DEPLOYMENTS_DIR, aliasName, ".json");
  }

  function readDeployment(
    string memory aliasName
  ) internal view returns (Types.Deployment memory) {
    return readDeploymentByPath(deploymentPath(aliasName));
  }

  function readDeploymentByPath(
    string memory path
  ) internal view returns (Types.Deployment memory deployment) {
    string memory json = vm.readFile(path);
    deployment.aliasName = vm.parseJsonString(json, ".alias");
    // Parsed strictly: every save writes the factory and resolver blocks, zeroed while
    // that contract is not deployed, so a missing key means a malformed record and must
    // not read as zero.
    deployment.factory = vm.parseJsonAddress(json, ".factory.address");
    deployment.resolver = vm.parseJsonAddress(json, ".resolver.address");

    // A zero address means the contract is not deployed yet, so the params beside it are
    // placeholders. Skipping them also avoids parsing the zeroed arrays back out.
    if (deployment.factory != address(0)) {
      deployment.factoryParams.deployer = vm.parseJsonAddress(json, ".factory.deployer");
      deployment.factoryParams.allowList = vm.parseJsonAddressArray(json, ".factory.args.allowList");
      deployment.factoryParams.encodedArgs = vm.parseJsonBytes(json, ".factory.encodedArgs");
    }

    if (deployment.resolver != address(0)) {
      deployment.resolverParams.salt = vm.parseJsonBytes32(json, ".resolver.salt");
      deployment.resolverParams.encodedArgs = vm.parseJsonBytes(json, ".resolver.encodedArgs");
    }

    // Absent array == nothing deployed yet (records are written one contract at a time).
    uint256 count = 0;
    while (vm.keyExistsJson(json, _verifierEntryKey(count, ""))) {
      ++count;
    }
    deployment.verifiers = new Types.VerifierDeployment[](count);
    for (uint256 i = 0; i < count; ++i) {
      bytes4 tag = _parseVersionTag(json, _verifierEntryKey(i, ".versionTag"), path);
      address addr = vm.parseJsonAddress(json, _verifierEntryKey(i, ".address"));
      require(addr != address(0), string.concat("ConfigLib: zero verifier address in ", path));
      for (uint256 j = 0; j < i; ++j) {
        require(
          deployment.verifiers[j].versionTag != tag,
          string.concat("ConfigLib: duplicate versionTag ", tagToString(tag), " in ", path)
        );
      }
      deployment.verifiers[i].versionTag = tag;
      deployment.verifiers[i].addr = addr;
      // Lenient on purpose, unlike the args below: records written before the key existed
      // all describe a plain CommitteeVerifier, so an absent key reads as exactly that.
      string memory contractKey = _verifierEntryKey(i, ".contract");
      deployment.verifiers[i].contractName =
        verifierContractName(vm.keyExistsJson(json, contractKey) ? vm.parseJsonString(json, contractKey) : "");
      // Parsed strictly like the blocks above: DeployVerifier writes every entry
      // complete, so a missing key means a malformed record.
      deployment.verifiers[i].feeAggregator = vm.parseJsonAddress(json, _verifierEntryKey(i, ".args.feeAggregator"));
      deployment.verifiers[i].allowlistAdmin = vm.parseJsonAddress(json, _verifierEntryKey(i, ".args.allowlistAdmin"));
      deployment.verifiers[i].storageLocations =
        vm.parseJsonStringArray(json, _verifierEntryKey(i, ".args.storageLocations"));
      deployment.verifiers[i].rmn = vm.parseJsonAddress(json, _verifierEntryKey(i, ".args.rmn"));
      deployment.verifiers[i].encodedArgs = vm.parseJsonBytes(json, _verifierEntryKey(i, ".encodedArgs"));
    }

    // Absent array == none deployed (and records written before the key existed).
    count = 0;
    while (vm.keyExistsJson(json, _adapterEntryKey(count, ""))) {
      ++count;
    }
    deployment.priceAdapters = new Types.PriceAdapterDeployment[](count);
    for (uint256 i = 0; i < count; ++i) {
      Types.PriceAdapterDeployment memory d = deployment.priceAdapters[i];
      d.addr = vm.parseJsonAddress(json, _adapterEntryKey(i, ".address"));
      require(d.addr != address(0), string.concat("ConfigLib: zero price adapter address in ", path));
      // Parsed strictly: the writer emits every args key, zero where unused.
      Types.PriceAdapterConfig memory a = d.args;
      a.contractName = vm.parseJsonString(json, _adapterEntryKey(i, ".contract"));
      a.token = vm.parseJsonAddress(json, _adapterEntryKey(i, ".args.token"));
      for (uint256 j = 0; j < i; ++j) {
        require(
          deployment.priceAdapters[j].args.token != a.token,
          string.concat("ConfigLib: duplicate price adapter token ", vm.toString(a.token), " in ", path)
        );
      }
      a.rateFeed = vm.parseJsonAddress(json, _adapterEntryKey(i, ".args.rateFeed"));
      a.usdFeed = vm.parseJsonAddress(json, _adapterEntryKey(i, ".args.usdFeed"));
      a.rateMaxStaleness = vm.parseJsonUint(json, _adapterEntryKey(i, ".args.rateMaxStaleness"));
      a.usdMaxStaleness = vm.parseJsonUint(json, _adapterEntryKey(i, ".args.usdMaxStaleness"));
      a.sequencerUptimeFeed = vm.parseJsonAddress(json, _adapterEntryKey(i, ".args.sequencerUptimeFeed"));
      a.gracePeriod = vm.parseJsonUint(json, _adapterEntryKey(i, ".args.gracePeriod"));
      d.encodedArgs = vm.parseJsonBytes(json, _adapterEntryKey(i, ".encodedArgs"));
    }
  }

  function _adapterEntryKey(
    uint256 index,
    string memory field
  ) private pure returns (string memory) {
    return string.concat(".priceAdapters[", vm.toString(index), "]", field);
  }

  /// @notice The price adapter recorded for `token`, or address(0) when none is.
  function priceAdapterByToken(
    Types.Deployment memory deployment,
    address token
  ) internal pure returns (address) {
    for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
      if (deployment.priceAdapters[i].args.token == token) return deployment.priceAdapters[i].addr;
    }
    return address(0);
  }

  function _verifierEntryKey(
    uint256 index,
    string memory field
  ) private pure returns (string memory) {
    return string.concat(".verifiers[", vm.toString(index), "]", field);
  }

  /// @notice The implementation a verifier entry names, with an unset name meaning the
  ///         stock CommitteeVerifier (the only implementation before the field existed).
  function verifierContractName(
    string memory contractName
  ) internal pure returns (string memory) {
    return bytes(contractName).length == 0 ? DEFAULT_VERIFIER_CONTRACT : contractName;
  }

  /// @notice The verifier deployed for `tag`. Reverts when that tag is not
  ///         recorded — deploy it first (DeployVerifier appends it to the record).
  function verifierByTag(
    Types.Deployment memory deployment,
    bytes4 tag
  ) internal pure returns (address) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (deployment.verifiers[i].versionTag == tag) return deployment.verifiers[i].addr;
    }
    revert(
      string.concat(
        "ConfigLib: no verifier with versionTag ",
        tagToString(tag),
        " recorded for ",
        deployment.aliasName,
        " - deploy that verifier first"
      )
    );
  }

  function hasVerifierTag(
    Types.Deployment memory deployment,
    bytes4 tag
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      if (deployment.verifiers[i].versionTag == tag) return true;
    }
    return false;
  }

  /// @notice Read the deployment record, or a zeroed struct (with alias set) if the
  ///         file does not exist yet. Lets deploy scripts merge one contract at a time.
  function readDeploymentOrEmpty(
    string memory aliasName
  ) internal view returns (Types.Deployment memory deployment) {
    string memory path = deploymentPath(aliasName);
    if (vm.exists(path)) return readDeploymentByPath(path);
    deployment.aliasName = aliasName;
  }

  /// @notice True for a `forge script` run with no `--broadcast`.
  /// @dev forge executes the entire script in simulation BEFORE submitting anything, so a
  ///      record written on a dry run describes a contract that was never deployed. Only
  ///      this one context is excluded: tests, `--broadcast` and `--resume` all record.
  function isDryRun() internal view returns (bool) {
    return vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
  }

  /// @notice Persist a deployment record to config/deployments/<alias>.json.
  function writeDeployment(
    Types.Deployment memory deployment
  ) internal {
    vm.createDir(DEPLOYMENTS_DIR, true); // idempotent
    writeDeploymentByPath(deploymentPath(deployment.aliasName), deployment);
  }

  /// @notice Persist a deployment record to an explicit path (used by tests).
  /// @dev Whole-file replacement, so a deploy script must read the record first and set
  ///      only its own contract's block. Redeploying a contract OVERRIDES its block; a
  ///      config edit alone never reaches this path.
  function writeDeploymentByPath(
    string memory path,
    Types.Deployment memory deployment
  ) internal {
    // Blocks are built with vm.serialize* (proper escaping for arrays and bytes) and the
    // top level is assembled by hand: string.concat cannot mis-nest, while relying on the
    // serializer to inline an array of objects could.
    string memory entries = "";
    for (uint256 i = 0; i < deployment.verifiers.length; ++i) {
      entries = string.concat(entries, i == 0 ? "" : ",", _serializeVerifierEntry(deployment.verifiers[i], i));
    }
    string memory adapters = "";
    for (uint256 i = 0; i < deployment.priceAdapters.length; ++i) {
      adapters = string.concat(adapters, i == 0 ? "" : ",", _serializeAdapterEntry(deployment.priceAdapters[i], i));
    }
    string memory json = string.concat(
      "{\"alias\":\"",
      deployment.aliasName,
      "\",\"factory\":",
      _serializeFactory(deployment.factory, deployment.factoryParams),
      ",\"resolver\":",
      _serializeResolver(deployment.resolver, deployment.resolverParams),
      ",\"verifiers\":[",
      entries,
      "],\"priceAdapters\":[",
      adapters,
      "]}"
    );
    vm.writeJson(json, path);
  }

  /// @dev Every block is written on every save, zeroed when the contract is not deployed
  ///      yet. Foundry's serializer keeps one in-memory object per objectKey for the whole
  ///      run, so a conditionally-emitted key would survive into a later write of a
  ///      different record.
  function _serializeFactory(
    address deployedAddress,
    Types.FactoryDeployParams memory params
  ) private returns (string memory) {
    string memory argsKey = "ccv_deployment_factory_args";
    string memory argsJson = vm.serializeAddress(argsKey, "allowList", params.allowList);

    string memory objectKey = "ccv_deployment_factory";
    vm.serializeAddress(objectKey, "address", deployedAddress);
    // Not a constructor argument: the CREATE address derives from this nonce-0 account,
    // which makes it the deploy-time input worth recording.
    vm.serializeAddress(objectKey, "deployer", params.deployer);
    vm.serializeString(objectKey, "args", argsJson);
    return vm.serializeBytes(objectKey, "encodedArgs", params.encodedArgs);
  }

  function _serializeResolver(
    address deployedAddress,
    Types.ResolverDeployParams memory params
  ) private returns (string memory) {
    string memory objectKey = "ccv_deployment_resolver";
    vm.serializeAddress(objectKey, "address", deployedAddress);
    // `salt` sits beside the address, not under `args`: it fixes the CREATE2 address
    // rather than being a constructor argument.
    vm.serializeBytes32(objectKey, "salt", params.salt);
    vm.serializeString(objectKey, "args", "{}");
    return vm.serializeBytes(objectKey, "encodedArgs", params.encodedArgs);
  }

  /// @dev The objectKey carries the array index: the serializer keeps one in-memory
  ///      object per key for the whole run, so entries sharing a key would bleed fields
  ///      into each other.
  function _serializeVerifierEntry(
    Types.VerifierDeployment memory entry,
    uint256 index
  ) private returns (string memory) {
    string memory argsKey = string.concat("ccv_deployment_verifier_args_", vm.toString(index));
    vm.serializeAddress(argsKey, "feeAggregator", entry.feeAggregator);
    vm.serializeAddress(argsKey, "allowlistAdmin", entry.allowlistAdmin);
    vm.serializeString(argsKey, "storageLocations", entry.storageLocations);
    string memory argsJson = vm.serializeAddress(argsKey, "rmn", entry.rmn);

    string memory objectKey = string.concat("ccv_deployment_verifier_", vm.toString(index));
    vm.serializeString(objectKey, "versionTag", tagToString(entry.versionTag));
    vm.serializeAddress(objectKey, "address", entry.addr);
    vm.serializeString(objectKey, "contract", verifierContractName(entry.contractName));
    vm.serializeString(objectKey, "args", argsJson);
    return vm.serializeBytes(objectKey, "encodedArgs", entry.encodedArgs);
  }

  /// @dev Every args key is written for every adapter, zero where that contract does not
  ///      take it: a conditionally-emitted key would bleed between records in one run
  ///      (see _serializeFactory), and the reader parses them all strictly.
  function _serializeAdapterEntry(
    Types.PriceAdapterDeployment memory entry,
    uint256 index
  ) private returns (string memory) {
    Types.PriceAdapterConfig memory a = entry.args;
    string memory argsKey = string.concat("ccv_deployment_adapter_args_", vm.toString(index));
    vm.serializeAddress(argsKey, "token", a.token);
    vm.serializeAddress(argsKey, "rateFeed", a.rateFeed);
    vm.serializeAddress(argsKey, "usdFeed", a.usdFeed);
    vm.serializeUint(argsKey, "rateMaxStaleness", a.rateMaxStaleness);
    vm.serializeUint(argsKey, "usdMaxStaleness", a.usdMaxStaleness);
    vm.serializeAddress(argsKey, "sequencerUptimeFeed", a.sequencerUptimeFeed);
    string memory argsJson = vm.serializeUint(argsKey, "gracePeriod", a.gracePeriod);

    string memory objectKey = string.concat("ccv_deployment_adapter_", vm.toString(index));
    vm.serializeString(objectKey, "contract", a.contractName);
    vm.serializeAddress(objectKey, "address", entry.addr);
    vm.serializeString(objectKey, "args", argsJson);
    return vm.serializeBytes(objectKey, "encodedArgs", entry.encodedArgs);
  }

  // --------------------------------------------------------------------------
  //  bytes4 parsing
  // --------------------------------------------------------------------------
  /// @dev Parse a 4-byte hex string (e.g. "0x00010001") into bytes4 unambiguously.
  ///      Uses parseJsonBytes (dynamic) + explicit big-endian reconstruction, so the
  ///      result does not depend on Foundry's fixed-bytes padding convention.
  function _parseBytes4(
    string memory json,
    string memory key
  ) private pure returns (bytes4) {
    bytes memory raw = vm.parseJsonBytes(json, key);
    require(raw.length == 4, "ConfigLib: expected a 4-byte hex value");
    return _toBytes4(raw);
  }

  function _toBytes4(
    bytes memory raw
  ) private pure returns (bytes4 result) {
    uint32 accumulated = 0;
    for (uint256 i = 0; i < 4; ++i) {
      accumulated = (accumulated << 8) | uint32(uint8(raw[i]));
    }
    result = bytes4(accumulated);
  }

  /// @notice Renders a versionTag as "0x00010001". `vm.toString(bytes4)` is a trap: the
  ///         argument widens to bytes32 and prints 64 hex chars.
  function tagToString(
    bytes4 tag
  ) internal pure returns (string memory) {
    bytes memory raw = new bytes(4);
    for (uint256 i = 0; i < 4; ++i) {
      raw[i] = tag[i];
    }
    return vm.toString(raw);
  }

  // --------------------------------------------------------------------------
  //  range-checked narrowing
  // --------------------------------------------------------------------------
  /// @dev Config numbers are hand-edited, so a bare downcast turns an out-of-range value
  ///      into a valid-looking smaller one with no error. A typo'd extra digit on a chain
  ///      selector is the dangerous case: any uint64 is a syntactically valid selector, so
  ///      nothing downstream can catch it and the lane targets the wrong chain.
  function _toUint64(
    uint256 value,
    string memory key
  ) private pure returns (uint64) {
    require(value <= type(uint64).max, string.concat("ConfigLib: ", key, " exceeds uint64"));
    // casting to 'uint64' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint64(value);
  }

  function _toUint32(
    uint256 value,
    string memory key
  ) private pure returns (uint32) {
    require(value <= type(uint32).max, string.concat("ConfigLib: ", key, " exceeds uint32"));
    // casting to 'uint32' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint32(value);
  }

  function _toUint16(
    uint256 value,
    string memory key
  ) private pure returns (uint16) {
    require(value <= type(uint16).max, string.concat("ConfigLib: ", key, " exceeds uint16"));
    // casting to 'uint16' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint16(value);
  }

  function _toUint8(
    uint256 value,
    string memory key
  ) private pure returns (uint8) {
    require(value <= type(uint8).max, string.concat("ConfigLib: ", key, " exceeds uint8"));
    // casting to 'uint8' is safe because the require above bounds `value`
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint8(value);
  }

  // --------------------------------------------------------------------------
  //  small string helpers
  // --------------------------------------------------------------------------
  function _hasPrefix(
    string memory text,
    string memory prefix
  ) private pure returns (bool) {
    bytes memory textBytes = bytes(text);
    bytes memory prefixBytes = bytes(prefix);
    if (prefixBytes.length > textBytes.length) return false;
    for (uint256 i = 0; i < prefixBytes.length; ++i) {
      if (textBytes[i] != prefixBytes[i]) return false;
    }
    return true;
  }

  function _hasSuffix(
    string memory text,
    string memory suffix
  ) private pure returns (bool) {
    bytes memory textBytes = bytes(text);
    bytes memory suffixBytes = bytes(suffix);
    if (suffixBytes.length > textBytes.length) return false;
    for (uint256 i = 0; i < suffixBytes.length; ++i) {
      if (textBytes[textBytes.length - suffixBytes.length + i] != suffixBytes[i]) return false;
    }
    return true;
  }

  /// @dev Byte-wise lexicographic `left < right`, for a deterministic `listLanes` order.
  function _stringLessThan(
    string memory left,
    string memory right
  ) private pure returns (bool) {
    bytes memory leftBytes = bytes(left);
    bytes memory rightBytes = bytes(right);
    uint256 shortest = leftBytes.length < rightBytes.length ? leftBytes.length : rightBytes.length;
    for (uint256 i = 0; i < shortest; ++i) {
      if (leftBytes[i] != rightBytes[i]) return uint8(leftBytes[i]) < uint8(rightBytes[i]);
    }
    return leftBytes.length < rightBytes.length;
  }

  function _contains(
    string memory text,
    string memory needle
  ) private pure returns (bool) {
    bytes memory textBytes = bytes(text);
    bytes memory needleBytes = bytes(needle);
    if (needleBytes.length == 0 || needleBytes.length > textBytes.length) return needleBytes.length == 0;
    for (uint256 i = 0; i <= textBytes.length - needleBytes.length; ++i) {
      bool matched = true;
      for (uint256 j = 0; j < needleBytes.length; ++j) {
        if (textBytes[i + j] != needleBytes[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }
}
