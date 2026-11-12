// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BpsConfigLib} from "../../src/lib/BpsConfigLib.sol";
import {ConfigLib} from "../../src/lib/ConfigLib.sol";
import {PriceAdapterLib} from "../../src/lib/PriceAdapterLib.sol";
import {Types} from "../../src/lib/Types.sol";
import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title ValidateConfig
/// @notice Eager, repo-wide config validation: parses EVERY real file under `config/`
///         through the same strict ConfigLib loaders the action scripts use, plus the
///         cross-file agreements (lane endpoints exist, selectors match, the operator
///         file carries a roles entry for every lane-pinned tag and the source's a
///         committee for it, a bidirectional pair agrees on the tag and mirrors its
///         selectors, every recorded resolver used the repo-wide resolverSalt, every
///         recorded price adapter is still declared with the args it was built from). One
///         [PASS]/[FAIL] line per file, no RPC.
/// @dev The action scripts parse lazily — a broken file surfaces only when the first
///      script touches it, possibly mid-ceremony. This runs the same parses up front.
///
/// Usage:
///   make validate-config
///   forge script script/governance/ValidateConfig.s.sol --tc ValidateConfig --sig "run()"
/// @dev The strict loaders revert on the first defect and forge forbids `this.`-calls in
///      scripts, so the parses run through this deployed seam — try/catch on an external
///      call keeps the run going and reports every file.
contract ConfigLoader {
  function loadOperatorFile() external view returns (uint256 tagCount, bytes32 salt) {
    tagCount = ConfigLib.readVersionTags().length;
    salt = ConfigLib.readResolverSalt();
  }

  function loadChain(
    string calldata path
  ) external view returns (Types.ChainConfig memory) {
    return ConfigLib.readChainByPath(path);
  }

  /// @dev Returns only the alias: the parse itself is the test, and the alias is all the
  ///      caller compares. Handing the whole struct back across the seam costs nothing
  ///      useful and is heavy to decode.
  function loadOperator(
    string calldata path
  ) external view returns (string memory aliasName) {
    return ConfigLib.readOperatorByPath(path).aliasName;
  }

  function loadLane(
    string calldata path
  ) external view returns (Types.LaneConfig memory) {
    return ConfigLib.readLaneByPath(path);
  }

  function loadDeployment(
    string calldata path
  ) external view returns (Types.Deployment memory) {
    return ConfigLib.readDeploymentByPath(path);
  }
}

/// @dev The bps-only keys, through their own seam so the stock path above is unchanged.
///      Each call reverts with the reason a file fails.
contract BpsConfigLoader {
  /// @notice A lane's `bpsFeeConfig`: the setFeeConfig bounds (enforced by the loader),
  ///         and a declared policy must not target a verifier recorded as a stock one.
  function checkLane(
    string calldata path
  ) external view returns (bool declared) {
    BpsConfigLib.LaneBpsFee memory lane = BpsConfigLib.readLaneBpsFeeByPath(path);
    declared = BpsConfigLib.isDeclared(lane.fee);
    if (declared) {
      BpsConfigLib.requireBpsTargetIfDeclared(lane.sourceAlias, lane.versionTag, string.concat("lane ", lane.laneName));
    }
  }

  /// @notice Each verifier entry's `requireAllTokensPriced`, same target rule.
  function checkOperator(
    string calldata path,
    string calldata aliasName
  ) external view {
    BpsConfigLib.VerifierBpsPolicy[] memory policies = BpsConfigLib.readVerifierPoliciesByPath(path);
    for (uint256 i = 0; i < policies.length; ++i) {
      if (!policies[i].requireAllTokensPriced) continue;
      BpsConfigLib.requireBpsTargetIfDeclared(aliasName, policies[i].versionTag, "requireAllTokensPriced");
    }
  }

  /// @notice `priceAdapters[]` vs the adapters recorded in config/deployments/<alias>.json:
  ///         an adapter cannot change after deploy, so a declaration that no longer matches
  ///         its record has silently stopped describing the chain.
  function checkPriceAdapters(
    string calldata path,
    string calldata aliasName
  ) external view {
    Types.Deployment memory deployment = ConfigLib.readDeploymentOrEmpty(aliasName);
    if (deployment.priceAdapters.length == 0) return;
    string memory err =
      PriceAdapterLib.declaredVsRecordedError(ConfigLib.readOperatorByPath(path).priceAdapters, deployment);
    require(bytes(err).length == 0, err);
  }
}

contract ValidateConfig is Script {
  error ValidationFailed(uint256 failures);

  ConfigLoader private s_loader;
  BpsConfigLoader private s_bpsLoader;

  // Mirrors ConfigLib's private dir layout.
  string private constant CHAINS_DIR = "config/chains/";
  string private constant LANES_DIR = "config/operator/lanes/";
  string private constant OPERATOR_DIR = "config/operator/chains/";
  string private constant DEPLOYMENTS_DIR = "config/deployments/";

  uint256 private s_checked;
  uint256 private s_failures;
  // Set once config/operator.json parses; the deployments check compares recorded salts to it.
  bool private s_haveSalt;
  bytes32 private s_resolverSalt;

  function run() external {
    console2.log(
      "[ValidateConfig] parsing every real file under config/ (templates, examples, zz-scratch fixtures skipped)"
    );
    s_loader = new ConfigLoader();
    vm.allowCheatcodes(address(s_loader));
    s_bpsLoader = new BpsConfigLoader();
    vm.allowCheatcodes(address(s_bpsLoader));

    _checkOperatorFile();
    _checkChains();
    _checkOperator();
    _checkLanes();
    _checkDeployments();

    console2.log("[ValidateConfig] files checked:", s_checked);
    if (s_failures > 0) {
      console2.log("DRIFT_DETECTED config validation failures:", s_failures);
      revert ValidationFailed(s_failures);
    }
    console2.log("[ValidateConfig] OK");
  }

  // ---------------------------------------------------------------------------
  //  layers
  // ---------------------------------------------------------------------------

  function _checkOperatorFile() private {
    string memory rel = "config/operator.json";
    if (!vm.exists(rel)) {
      _fail(rel, "missing - run: make seed-operator-config");
      return;
    }
    try s_loader.loadOperatorFile() returns (uint256 n, bytes32 salt) {
      s_haveSalt = true;
      s_resolverSalt = salt;
      // An empty catalog cannot serve any lane: requireKnownTag rejects every tag.
      if (n == 0) {
        _fail(rel, "no versionTags catalogued - add the tag each lane pins, e.g. 0x00010001");
      } else {
        _pass(rel, string.concat(vm.toString(n), " tags"));
      }
    } catch Error(string memory reason) {
      _fail(rel, reason);
    } catch {
      _fail(rel, "malformed");
    }
  }

  function _checkChains() private {
    string[] memory paths = _realJsonFiles(CHAINS_DIR);

    for (uint256 i = 0; i < paths.length; ++i) {
      string memory aliasName = _basename(paths[i]);
      string memory rel = string.concat(CHAINS_DIR, aliasName, ".json");
      try s_loader.loadChain(paths[i]) returns (Types.ChainConfig memory chainConfig) {
        if (!_eq(chainConfig.aliasName, aliasName)) {
          _fail(rel, string.concat("declares alias '", chainConfig.aliasName, "' (must equal the filename)"));
          continue;
        }
        if (chainConfig.chainId == 0) {
          _fail(rel, string.concat("chainId is zero - run: make sync-chain CHAIN=", aliasName));
          continue;
        }
        _pass(rel, "");
      } catch Error(string memory reason) {
        _fail(rel, reason);
      } catch {
        _fail(rel, "malformed");
      }
    }
  }

  function _checkOperator() private {
    string[] memory paths = _realJsonFiles(OPERATOR_DIR);
    for (uint256 i = 0; i < paths.length; ++i) {
      string memory aliasName = _basename(paths[i]);
      string memory rel = string.concat(OPERATOR_DIR, aliasName, ".json");
      try s_loader.loadOperator(paths[i]) returns (string memory declared) {
        if (!_eq(declared, aliasName)) {
          _fail(rel, string.concat("declares alias '", declared, "' (must equal the filename)"));
        } else {
          _pass(rel, "");
          _checkOperatorBps(rel, paths[i], aliasName);
        }
      } catch Error(string memory reason) {
        _fail(rel, reason);
      } catch {
        _fail(rel, "malformed");
      }
    }
  }

  function _checkLanes() private {
    string[] memory paths = ConfigLib.listLanes();
    Types.LaneConfig[] memory parsed = new Types.LaneConfig[](paths.length);
    uint256 parsedCount = 0;

    for (uint256 i = 0; i < paths.length; ++i) {
      string memory laneName = _basename(paths[i]);
      string memory rel = string.concat(LANES_DIR, laneName, ".json");
      try s_loader.loadLane(paths[i]) returns (Types.LaneConfig memory lane) {
        if (!_eq(lane.name, laneName)) {
          _fail(rel, string.concat("declares name '", lane.name, "' (must equal the filename)"));
          continue;
        }
        _pass(rel, "");
        _checkLaneBps(rel, paths[i]);
        _checkLaneEndpoint(rel, lane, lane.source.aliasName, lane.source.chainSelector, "source");
        _checkLaneEndpoint(rel, lane, lane.dest.aliasName, lane.dest.chainSelector, "dest");
        parsed[parsedCount++] = lane;
      } catch Error(string memory reason) {
        _fail(rel, reason);
      } catch {
        _fail(rel, "malformed");
      }
    }

    // Trimmed to what actually parsed, so the cross-lane checks can trust `.length`.
    Types.LaneConfig[] memory lanes = new Types.LaneConfig[](parsedCount);
    for (uint256 i = 0; i < parsedCount; ++i) {
      lanes[i] = parsed[i];
    }

    _checkLanePairs(lanes);
  }

  /// @dev A bidirectional lane is TWO files and nothing forces them to agree. Two files
  ///      pair when each one's `source.alias` is the other's `dest.alias`. The tag is a
  ///      cross-chain identity, so a divergence means the files describe different
  ///      topologies. `i < j` reports each pair once; a one-way lane has no reverse.
  function _checkLanePairs(
    Types.LaneConfig[] memory lanes
  ) private {
    for (uint256 i = 0; i < lanes.length; ++i) {
      for (uint256 j = i + 1; j < lanes.length; ++j) {
        bool isReverse = _eq(lanes[i].source.aliasName, lanes[j].dest.aliasName)
          && _eq(lanes[i].dest.aliasName, lanes[j].source.aliasName);
        if (!isReverse) continue;

        string memory rel = string.concat(LANES_DIR, lanes[i].name, ".json");
        if (lanes[i].versionTag != lanes[j].versionTag) {
          _fail(
            rel,
            string.concat(
              "versionTag ",
              ConfigLib.tagToString(lanes[i].versionTag),
              " but reverse lane ",
              lanes[j].name,
              " pins ",
              ConfigLib.tagToString(lanes[j].versionTag),
              " - a lane pair shares one tag"
            )
          );
        }
        if (
          lanes[i].source.chainSelector != lanes[j].dest.chainSelector
            || lanes[i].dest.chainSelector != lanes[j].source.chainSelector
        ) {
          _fail(rel, string.concat("chain selectors do not mirror reverse lane ", lanes[j].name));
        }
      }
    }
  }

  /// @dev Per endpoint: the chain file must exist and agree on the selector, and the
  ///      operator file must carry a verifiers[] entry for the lane's tag — DeployVerifier
  ///      refuses without one, so a gap here fails the ceremony later anyway. The source
  ///      must also declare the committee every destination applies for this lane.
  function _checkLaneEndpoint(
    string memory lanePath,
    Types.LaneConfig memory lane,
    string memory aliasName,
    uint64 laneSelector,
    string memory side
  ) private {
    string memory chainPath = string.concat(CHAINS_DIR, aliasName, ".json");
    if (!vm.exists(chainPath)) {
      _fail(
        lanePath,
        string.concat(
          side, " chain has no config - run: make add-chain CHAIN=", aliasName, " SELECTOR=", vm.toString(laneSelector)
        )
      );
      return;
    }
    Types.ChainConfig memory chainConfig = ConfigLib.readChainOrEmpty(aliasName);
    if (chainConfig.chainSelector != laneSelector) {
      _fail(
        lanePath,
        string.concat(side, " selector does not match ", chainPath, " - the chain file is API-synced; fix the lane")
      );
    }
    Types.OperatorConfig memory operator = ConfigLib.readOperatorOrEmpty(aliasName);
    if (!ConfigLib.hasVerifierConfigTag(operator, lane.versionTag)) {
      _fail(
        lanePath,
        string.concat(
          "operator/chains/",
          aliasName,
          ".json has no verifiers[] entry for tag ",
          ConfigLib.tagToString(lane.versionTag),
          " - add one; deploy-verifier refuses without it"
        )
      );
    }
    if (
      _eq(side, "source") && ConfigLib.hasVerifierConfigTag(operator, lane.versionTag)
        && ConfigLib.verifierConfigByTag(operator, lane.versionTag).signatureConfig.threshold == 0
    ) {
      _fail(
        lanePath,
        string.concat(
          "operator/chains/",
          aliasName,
          ".json declares no committee for tag ",
          ConfigLib.tagToString(lane.versionTag),
          " - signatureConfig signs messages leaving this chain; every destination applies it"
        )
      );
    }
  }

  /// @dev Bps-only keys, reported against the same file. Silent when the file has none.
  function _checkLaneBps(
    string memory rel,
    string memory path
  ) private {
    try s_bpsLoader.checkLane(path) returns (bool) {}
    catch Error(string memory reason) {
      _fail(rel, reason);
    } catch {
      _fail(rel, "bpsFeeConfig malformed");
    }
  }

  function _checkOperatorBps(
    string memory rel,
    string memory path,
    string memory aliasName
  ) private {
    try s_bpsLoader.checkOperator(path, aliasName) {}
    catch Error(string memory reason) {
      _fail(rel, reason);
    } catch {
      _fail(rel, "requireAllTokensPriced malformed");
    }
    try s_bpsLoader.checkPriceAdapters(path, aliasName) {}
    catch Error(string memory reason) {
      _fail(rel, reason);
    } catch {
      _fail(rel, "priceAdapters could not be compared with the deployment record");
    }
  }

  function _checkDeployments() private {
    string[] memory paths = _realJsonFiles(DEPLOYMENTS_DIR);
    for (uint256 i = 0; i < paths.length; ++i) {
      string memory aliasName = _basename(paths[i]);
      string memory rel = string.concat(DEPLOYMENTS_DIR, aliasName, ".json");
      try s_loader.loadDeployment(paths[i]) returns (Types.Deployment memory deployment) {
        if (!_eq(deployment.aliasName, aliasName)) {
          _fail(rel, string.concat("declares alias '", deployment.aliasName, "' (must equal the filename)"));
        } else if (s_haveSalt && deployment.resolver != address(0) && deployment.resolverParams.salt != s_resolverSalt)
        {
          _fail(rel, "recorded resolver salt differs from config/operator.json resolverSalt");
        } else {
          _pass(rel, "");
        }
      } catch Error(string memory reason) {
        _fail(rel, reason);
      } catch {
        _fail(rel, "malformed");
      }
    }
  }

  // ---------------------------------------------------------------------------
  //  reporting + path helpers
  // ---------------------------------------------------------------------------

  function _pass(
    string memory path,
    string memory note
  ) private {
    ++s_checked;
    console2.log(string.concat("  [PASS] ", path, bytes(note).length == 0 ? "" : string.concat(" (", note, ")")));
  }

  function _fail(
    string memory path,
    string memory reason
  ) private {
    ++s_checked;
    ++s_failures;
    console2.log(string.concat("  [FAIL] ", path, ": ", reason));
  }

  /// @dev Real config files only: `.json`, not templates, not examples, not test
  ///      fixtures (`zz-scratch-` is the repo-wide fixture marker, cf. deployments-report.sh).
  function _realJsonFiles(
    string memory dir
  ) private view returns (string[] memory paths) {
    if (!vm.exists(dir)) return new string[](0);
    Vm.DirEntry[] memory entries = vm.readDir(dir);
    string[] memory buf = new string[](entries.length);
    uint256 n = 0;
    for (uint256 i = 0; i < entries.length; ++i) {
      string memory p = entries[i].path;
      if (
        _hasSuffix(p, ".json") && !_contains(p, "_template") && !_contains(p, ".example.")
          && !_contains(p, "zz-scratch-")
      ) {
        buf[n++] = p;
      }
    }
    paths = new string[](n);
    for (uint256 i = 0; i < n; ++i) {
      paths[i] = buf[i];
    }
  }

  /// @dev `vm.readDir` returns absolute paths, so split on the last '/' rather than
  ///      stripping a relative prefix; then drop the ".json" suffix.
  function _basename(
    string memory path
  ) private pure returns (string memory) {
    bytes memory p = bytes(path);
    uint256 start = 0;
    for (uint256 i = 0; i < p.length; ++i) {
      if (p[i] == "/") start = i + 1;
    }
    bytes memory out = new bytes(p.length - start - 5);
    for (uint256 i = 0; i < out.length; ++i) {
      out[i] = p[start + i];
    }
    return string(out);
  }

  function _eq(
    string memory a,
    string memory b
  ) private pure returns (bool) {
    return keccak256(bytes(a)) == keccak256(bytes(b));
  }

  function _hasSuffix(
    string memory s,
    string memory suffix
  ) private pure returns (bool) {
    bytes memory b = bytes(s);
    bytes memory suf = bytes(suffix);
    if (suf.length > b.length) return false;
    for (uint256 i = 0; i < suf.length; ++i) {
      if (b[b.length - suf.length + i] != suf[i]) return false;
    }
    return true;
  }

  function _contains(
    string memory s,
    string memory needle
  ) private pure returns (bool) {
    bytes memory b = bytes(s);
    bytes memory n = bytes(needle);
    if (n.length == 0 || n.length > b.length) return false;
    for (uint256 i = 0; i + n.length <= b.length; ++i) {
      bool hit = true;
      for (uint256 j = 0; j < n.length; ++j) {
        if (b[i + j] != n[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }
}
