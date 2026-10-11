// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../../script/DeployKilim.s.sol";
import {KilimAuction} from "../../src/KilimAuction.sol";
import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../src/KilimOneOfOne.sol";
import {TestBase} from "../TestBase.sol";

interface VmG {
    function readFileBinary(string calldata) external view returns (bytes memory);
}

/// @dev The script's private arithmetic, exposed: how it measures a chunk and a contract creation.
contract DeployKilimGasProbe is DeployKilim {
    function create2Measured(bytes memory initcode, address expected) external returns (uint256) {
        return _create2(initcode, expected, "chunk");
    }

    function sstore2(bytes memory data) external pure returns (bytes memory) {
        return _sstore2(data);
    }

    function predict(bytes memory initcode) external pure returns (address) {
        return _predict(initcode);
    }

    function intrinsic(bytes memory data) external pure returns (uint256) {
        return _intrinsic(data);
    }
}

/// @notice Review PoC (deploy lens). Finding: the deploy script and forge's simulation are pinned to
///         Cancun prices (foundry.toml `evm_version = "cancun"`); on a Glamsterdam chain (Sepolia since
///         2026-10-06, mainnet at an unset date) every chunk broadcast would be sent with about 7.8M gas
///         against about 38M needed, and the three contracts' code deposit (15-17M of state gas each) is
///         absent from the plan.
///
///         Scenario: the artist runs the documented Sepolia rehearsal (checklists/2-deploy.md:17-22,
///         `runStore()` with `--broadcast --slow`, neither `--skip-simulation` nor `-g`). forge takes each
///         transaction's gas limit from its own Cancun simulation times the default 130%: the script's
///         dry run logs about 6.0M for a full chunk, "under 8M", and forge signs chunk 0 with about 7.8M.
///         Under EIP-8037 the CREATE2 of a 24,576-byte runtime charges (120 + 24,576) x 1,530 of state gas
///         at code deposit; a 7.8M transaction has no state-gas reservoir, the creating frame halts, the
///         transaction fails, `--slow` stops the run with the gas burnt and no chunk on the chain. The
///         contracts phase is the same story at (120 + runtime) x 1,530 per contract, with the deployer's
///         nonce spent by the failed creation.
///
///         forge 1.7.1 has no Glamsterdam schedule to select, so the chain side is EIP-8037 as published
///         (Last Call, deadline 2026-11-01), applied by hand exactly as test/AttackPatterns.t.sol and
///         test/review/PrizeGasBudget.t.sol already do for storage. The desired property: the gas limit
///         forge signs for each documented broadcast covers what the target chain charges for it.
contract GlamsterdamBroadcastGasPoC is TestBase {
    VmG private constant vmg = VmG(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// forge script: `-g, --gas-estimate-multiplier <GAS_ESTIMATE_MULTIPLIER> [default: 130]`; the
    /// broadcast gas limit is the simulation's gas_used times this, over 100, unless --skip-simulation.
    uint256 private constant GAS_ESTIMATE_MULTIPLIER = 130;
    /// Cancun: code deposit per byte of runtime, inside the execution gas forge measures.
    uint256 private constant CODE_DEPOSIT_TODAY = 200;
    /// EIP-8037 as published: state gas per byte (CPSB) and the bytes charged for a new account.
    uint256 private constant CPSB = 1_530;
    uint256 private constant STATE_BYTES_PER_NEW_ACCOUNT = 120;
    /// EIP-7825: the per-transaction cap, which EIP-8037 keeps for execution gas only.
    uint256 private constant EXECUTION_GAS_BUDGET = 16_777_216;

    /// A full page chunk as packed on 10 October (24,575 data bytes, runtime 0x00 || data).
    string private constant FULL_CHUNK = "../onchain/build-page/chunks/prefix_00.bin";

    DeployKilimGasProbe internal script;

    event log_named_uint(string key, uint256 value);

    function setUp() public {
        script = new DeployKilimGasProbe();
    }

    /// @dev EIP-8037's charge for creating an account with `runtime` bytes of code: the deposit leaves the
    ///      execution gas and becomes state gas. A transaction's gas limit funds both pools (the state
    ///      reservoir is whatever the limit holds above the execution budget, and a charge the reservoir
    ///      cannot pay comes out of the execution gas left), so the limit must cover their sum.
    function _glamsterdamNeed(uint256 cancunGas, uint256 runtime) private pure returns (uint256) {
        uint256 execution = cancunGas - CODE_DEPOSIT_TODAY * runtime;
        require(execution <= EXECUTION_GAS_BUDGET, "execution over the EIP-7825 budget");
        uint256 state = (STATE_BYTES_PER_NEW_ACCOUNT + runtime) * CPSB;
        return execution + state;
    }

    /// @dev What forge signs under the documented flags: the Cancun simulation's gas times 130%.
    function _forgeLimit(uint256 simulated) private pure returns (uint256) {
        return simulated * GAS_ESTIMATE_MULTIPLIER / 100;
    }

    /// Phase 1, chunk 0 of the Sepolia rehearsal: the gas limit forge signs must cover the chunk's cost
    /// on the chain it is sent to.
    function testStoreChunkBroadcastCoversGlamsterdamCodeDeposit() public {
        bytes memory data = vmg.readFileBinary(FULL_CHUNK);
        assertEq(data.length, CHUNK);
        bytes memory initcode = script.sstore2(data);
        address expected = script.predict(initcode);

        // The script's own measurement, exactly as `deployStore`'s dry run logs it, under its 8M policy.
        uint256 simulated = script.create2Measured(initcode, expected);
        uint256 runtime = expected.code.length;
        assertEq(runtime, CHUNK + 1);
        assertTrue(simulated <= script.MAX_TX_GAS()); // the policy passes: "under 8M"

        uint256 signed = _forgeLimit(simulated);
        uint256 need = _glamsterdamNeed(simulated, runtime);
        emit log_named_uint("chunk: Cancun simulation (what the dry run logs)", simulated);
        emit log_named_uint("chunk: gas limit forge signs (x 130%)", signed);
        emit log_named_uint("chunk: state gas for the code deposit under EIP-8037", (120 + runtime) * CPSB);
        emit log_named_uint("chunk: gas the transaction needs under EIP-8037", need);
        assertTrue(signed >= need);
    }

    /// Phase 2, the three creations from orkhanart.eth: each signed limit must cover at least the code
    /// deposit of the contract it creates (storage writes come on top).
    function testContractBroadcastsCoverGlamsterdamCodeDeposit() public {
        KilimAuction.Config memory c = config();
        address deployer = address(0xD3910);
        address auction = vm.computeCreateAddress(deployer, 2);

        // KilimMotifs at nonce 0 and KilimOneOfOne at nonce 1, naming the auction at nonce 2.
        vm.startPrank(deployer);
        uint256 g = gasleft();
        KilimMotifs motifs = newMotifs(auction, TREASURY, MOTIF_CAP);
        g -= gasleft();
        uint256 motifsGas =
            g + script.intrinsic(bytes.concat(type(KilimMotifs).creationCode, _motifsArgs(auction)));

        g = gasleft();
        KilimOneOfOne oneOfOne = newOneOfOne(auction, TREASURY, motifs);
        g -= gasleft();
        bytes memory oneArgs = _oneOfOneArgs(auction, motifs);
        uint256 oneGas = g + script.intrinsic(bytes.concat(type(KilimOneOfOne).creationCode, oneArgs));

        c.motifs = address(motifs);
        c.oneOfOne = address(oneOfOne);
        g = gasleft();
        KilimAuction a = new KilimAuction(c);
        g -= gasleft();
        uint256 auctionGas =
            g + script.intrinsic(bytes.concat(type(KilimAuction).creationCode, abi.encode(c)));
        vm.stopPrank();
        assertEq(address(a), auction);

        bool covered = true;
        covered = _check("KilimMotifs", motifsGas, address(motifs).code.length) && covered;
        covered = _check("KilimOneOfOne", oneGas, address(oneOfOne).code.length) && covered;
        covered = _check("KilimAuction", auctionGas, address(a).code.length) && covered;
        assertTrue(covered);
    }

    function _check(string memory what, uint256 simulated, uint256 runtime) private returns (bool) {
        uint256 signed = _forgeLimit(simulated);
        uint256 deposit = (STATE_BYTES_PER_NEW_ACCOUNT + runtime) * CPSB;
        emit log_named_uint(string.concat(what, ": Cancun creation gas (what the dry run logs)"), simulated);
        emit log_named_uint(string.concat(what, ": gas limit forge signs (x 130%)"), signed);
        emit log_named_uint(string.concat(what, ": runtime bytes"), runtime);
        emit log_named_uint(string.concat(what, ": state gas for its code deposit under EIP-8037"), deposit);
        return signed >= deposit;
    }

    function _motifsArgs(address minter) private pure returns (bytes memory) {
        // Only the length matters for the intrinsic cost; the stand-in store's shape (two grid chunks).
        return abi.encode(
            minter,
            TREASURY,
            MOTIF_CAP,
            new address[](2),
            bytes32(0),
            address(0),
            bytes32(0),
            DESCRIPTION,
            EXTERNAL_URL
        );
    }

    function _oneOfOneArgs(address minter, KilimMotifs motifs) private returns (bytes memory) {
        KilimOneOfOne.Page memory page = standInPage();
        return abi.encode(minter, TREASURY, motifs, page, ONE_OF_ONE_NAME, DESCRIPTION, EXTERNAL_URL);
    }
}
