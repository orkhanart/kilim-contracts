// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimBazaar} from "../../../src/KilimBazaar.sol";
import {KilimAuction} from "../../../src/KilimAuction.sol";
import {KilimMotifs} from "../../../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../../../src/KilimOneOfOne.sol";
import {BazaarBase, VmBazaar, FakeAuction} from "../../../test/bazaar/BazaarBase.sol";

/// @notice AI audit 2026-10-12, lens "the Kilim Bazaar seal and the metadata it produces".
///         SL-* tests are proofs of concept for findings (they PASS when the described behaviour is present);
///         check_* tests pin what was checked and found sound.
contract SealAuditTest is BazaarBase {
    event SeedRearmed(uint256 indexed tokenId, uint256 sealBlock);
    event KilimSealed(uint256 indexed tokenId, bytes32 blockHash, uint256 seed);
    event MetadataUpdate(uint256 _tokenId);

    uint256 internal constant B = 23_000_000;
    /// The page's mulberry32 is seeded with seed ^ 0x5bd1e995 (bazaar.js weave); its first draw picks the pattern.
    uint32 internal constant PAGE_SALT = 0x5bd1e995;
    /// eth_getCode(0x0000F90827F1C53a10cb7A02335B175320002935) on Ethereum mainnet, 12 October 2026
    /// (head 26,176,868, ethereum-rpc.publicnode.com).
    bytes internal constant MAINNET_HISTORY_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(B);
        _deployAuction(BIG_CAP, FIXTURE_PAGE);
        vmb.etch(HISTORY, MAINNET_HISTORY_CODE);
        _deployBazaar();
        assertEq(bazaar.seedWindow(), 8191);
    }

    // ------------------------------------------------------------ helpers

    function _list(uint256 a) internal pure returns (uint256[] memory l) {
        l = new uint256[](1);
        l[0] = a;
    }

    function _seedOf(bytes32 h, uint256 id) internal view returns (uint256) {
        return uint32(uint256(keccak256(abi.encode(h, address(bazaar), id))));
    }

    /// @dev Math.imul: the low 32 bits of the product.
    function _imul(uint32 x, uint32 y) internal pure returns (uint32) {
        unchecked {
            return uint32(uint256(x) * uint256(y));
        }
    }

    /// @dev field.js rng (mulberry32), first output, as an unsigned 32-bit integer.
    function _mulberryFirst(uint32 init) internal pure returns (uint32) {
        unchecked {
            uint32 a = init + 0x6D2B79F5;
            uint32 b = a;
            b = _imul(b ^ (b >> 15), b | 1);
            b ^= b + _imul(b ^ (b >> 7), b | 61);
            return b ^ (b >> 14);
        }
    }

    /// @dev The pattern index the page draws first for this seed from a pool of `len`:
    ///      Math.floor(rng(seed ^ 0x5bd1e995)() * len) = (out * len) >> 32.
    function _pick(uint256 seed, uint256 len) internal pure returns (uint256) {
        return (uint256(_mulberryFirst(uint32(seed) ^ PAGE_SALT)) * len) >> 32;
    }

    /// @dev What "the network" makes block n's hash in these simulations.
    function _chainHash(uint256 n, uint256 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode("block hash", n, salt));
    }

    // ------------------------------------------------------------ the page's draw, ported

    /// @dev The port agrees with node running field.js rng on these seeds (values computed with
    ///      research/motifs/curate/living-language-v3/source/field.js, 12 October 2026).
    function test_check_PagePickPortMatchesFieldJs() public pure {
        assertEq(_mulberryFirst(uint32(0) ^ PAGE_SALT), 2960403258);
        assertEq(_mulberryFirst(uint32(1) ^ PAGE_SALT), 1517829247);
        assertEq(_mulberryFirst(uint32(0xdeadbeef) ^ PAGE_SALT), 3462871639);
        assertEq(_mulberryFirst(uint32(0x0badf00d) ^ PAGE_SALT), 2942242371);
        assertEq(_mulberryFirst(uint32(0xffffffff) ^ PAGE_SALT), 1013810710);
        assertEq(_mulberryFirst(uint32(123456789) ^ PAGE_SALT), 2408761270);
        assertEq(_pick(0, 10), 6);
        assertEq(_pick(0, 69), 47);
        assertEq(_pick(0xdeadbeef, 69), 55);
        assertEq(_pick(0xffffffff, 69), 16);
    }

    // ------------------------------------------------------------ SL-1: withholding re-rolls (no sealer exists)

    /// @dev SL-1. The owner never signs the site's second ("seal") prompt; no independent sealer exists in the
    ///      repo. From block sealBlock + 1 the owner computes the seed (and the page's look) off-chain, and
    ///      when it is not the one wanted waits out the 8,191-block window and re-arms. Here: an Apprentice,
    ///      the target is a specific one of its 10 fields that the first draw did not give.
    function test_SL1_OwnerWithholdsAndReArmsUntilTheApprenticeHasTheFieldTheyWant() public {
        _settle(10 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        assertEq(bazaar.kilim(id).rank, 1); // Apprentice: pool of 10 fields
        uint256 sb = bazaar.kilim(id).sealBlock;
        uint256 first = _pick(_seedOf(_chainHash(sb, 0), id), 10);
        uint256 target = (first + 1) % 10;
        uint256 startBlock = block.number;
        uint256 draws;
        uint256 rearmGas;
        for (draws = 1; draws <= 300; ++draws) {
            // the network mines the seal block; the owner reads its hash from the chain
            vm.roll(sb + 1);
            vmb.setBlockhash(sb, _chainHash(sb, 0));
            uint256 predicted = _seedOf(blockhash(sb), id);
            if (_pick(predicted, 10) == target) {
                // the look is the wanted one: the owner seals it (or lets the site do it)
                vm.prank(ALICE);
                assertEq(bazaar.seal(_list(id)), 1);
                assertEq(bazaar.kilim(id).seed, predicted); // what was previewed is what was sealed
                break;
            }
            // not wanted: nobody seals for 8,192 blocks (the history contract keeps the hash readable
            // until then, so a third party could still lock it in)
            vm.roll(sb + 8191);
            assertEq(bazaar.sealState(id), 2);
            vm.roll(sb + 8192);
            assertEq(bazaar.sealState(id), 3);
            vm.prank(ALICE);
            uint256 g = gasleft();
            assertEq(bazaar.seal(_list(id)), 0); // re-armed: a fresh draw
            rearmGas = g - gasleft();
            sb = bazaar.kilim(id).sealBlock;
            assertEq(sb, block.number + 1);
        }
        assertTrue(draws > 1 && draws <= 300);
        assertEq(_pick(bazaar.kilim(id).seed, 10), target);
        assertTrue(bazaar.kilim(id).flags & bazaar.SEALED() != 0);
        _log(string.concat("SL-1 Apprentice: draws needed ", vm.toString(draws)));
        _log(string.concat("SL-1 blocks elapsed ", vm.toString(block.number - startBlock)));
        _log(string.concat("SL-1 hours at 12 s/block ", vm.toString((block.number - startBlock) * 12 / 3600)));
        _log(string.concat("SL-1 gas per re-arm call (inner) ", vm.toString(rearmGas)));
    }

    /// @dev SL-1, the Master. At a 0.01 ETH close top = 10, so every 10-motif kilim is The Master, whose pool
    ///      of 69 ends with the three games only Masters have (indices 66..68). The owner re-rolls until one.
    function test_SL1_OwnerReRollsAMasterUntilItIsOneOfTheThreeGames() public {
        _settle(0.01 ether);
        vm.roll(B);
        assertEq(bazaar.masterCost(), 10);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        assertEq(bazaar.kilim(id).rank, 6);
        uint256 sb = bazaar.kilim(id).sealBlock;
        uint256 startBlock = block.number;
        uint256 draws;
        for (draws = 1; draws <= 500; ++draws) {
            vm.roll(sb + 1);
            vmb.setBlockhash(sb, _chainHash(sb, 1));
            uint256 predicted = _seedOf(blockhash(sb), id);
            if (_pick(predicted, 69) >= 66) {
                vm.prank(ALICE);
                assertEq(bazaar.seal(_list(id)), 1);
                break;
            }
            vm.roll(sb + 8192);
            vm.prank(ALICE);
            bazaar.seal(_list(id));
            sb = bazaar.kilim(id).sealBlock;
        }
        assertTrue(draws > 1 && draws <= 500);
        assertTrue(_pick(bazaar.kilim(id).seed, 69) >= 66);
        _log(string.concat("SL-1 Master game: draws needed ", vm.toString(draws)));
        _log(string.concat("SL-1 Master days at 12 s/block ", vm.toString((block.number - startBlock) * 12 / 86400)));
    }

    /// @dev The counter to SL-1 works when it exists: one seal by anyone inside the window fixes the first
    ///      draw for good, and the owner's later re-arm attempt does nothing.
    function test_check_AThirdPartySealInsideTheWindowEndsTheReRoll() public {
        _settle(10 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        uint256 sb = bazaar.kilim(id).sealBlock;
        vm.roll(sb + 1 + 4000); // the history path
        vmb.store(HISTORY, bytes32(sb % 8191), _chainHash(sb, 0));
        vm.prank(BOB);
        assertEq(bazaar.seal(_list(id)), 1);
        uint256 seed = bazaar.kilim(id).seed;
        assertEq(seed, _seedOf(_chainHash(sb, 0), id));
        vm.roll(sb + 100_000);
        vm.prank(ALICE);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.kilim(id).seed, seed);
        assertEq(bazaar.kilim(id).sealBlock, sb);
    }

    // ------------------------------------------------------------ SL-2 / SL-3: who builds the seal block

    /// @dev SL-2. After a lapse the re-arm sets sealBlock = block.number + 1 of whoever calls seal: any caller,
    ///      not only the owner, chooses which block's hash becomes the seed. A caller who builds (or pays the
    ///      builder of) that next block grinds its header (extraData) and sets the look; here CAROL, a stranger,
    ///      gives Alice's lapsed Apprentice field 9.
    function test_SL2_AfterALapseAnyCallerTimesTheReArmToABlockTheyBuildAndPicksTheLook() public {
        _settle(10 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        // nobody sealed it in time; CAROL waits for a block whose successor she builds
        vm.roll(B + 1 + 8192 + 777);
        uint256 n = block.number;
        vm.prank(CAROL);
        bazaar.seal(_list(id));
        assertEq(bazaar.kilim(id).sealBlock, n + 1);
        // CAROL builds block n + 1: each extraData value is another candidate hash
        uint256 target = 9;
        uint256 tries;
        bytes32 h;
        for (tries = 1; tries < 10_000; ++tries) {
            h = keccak256(abi.encode("block n+1 header, extraData", tries));
            if (_pick(_seedOf(h, id), 10) == target) break;
        }
        vm.roll(n + 2);
        vmb.setBlockhash(n + 1, h);
        vm.prank(BOB); // anyone seals; the result is the same
        assertEq(bazaar.seal(_list(id)), 1);
        assertEq(_pick(bazaar.kilim(id).seed, 10), target);
        _log(string.concat("SL-2 header candidates tried ", vm.toString(tries)));
    }

    /// @dev SL-3 (accepted residual risk, quantified). The builder of block B+1 grinds its header for a kilim
    ///      made in block B: the same full control without any lapse. A whole 32-bit seed takes about 2^32
    ///      header hashes; a first-order look (the pattern) about pool-size tries. Here: a Master game.
    function test_SL3_TheBuilderOfTheSealBlockPicksAMastersGameInAFewDozenHashes() public {
        _settle(0.01 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        uint256 sb = bazaar.kilim(id).sealBlock;
        assertEq(sb, B + 1);
        uint256 tries;
        bytes32 h;
        for (tries = 1; tries < 10_000; ++tries) {
            h = keccak256(abi.encode("block B+1 header, extraData", tries));
            if (_pick(_seedOf(h, id), 69) >= 66) break;
        }
        vm.roll(sb + 1);
        vmb.setBlockhash(sb, h);
        assertEq(bazaar.seal(_list(id)), 1);
        assertTrue(_pick(bazaar.kilim(id).seed, 69) >= 66);
        _log(string.concat("SL-3 header candidates tried ", vm.toString(tries)));
    }

    // ------------------------------------------------------------ the history contract

    /// @dev The mainnet code hashes to HISTORY_CODEHASH, and the fixture's code is the mainnet code.
    function test_check_HistoryCodehashIsMainnets() public view {
        assertEq(keccak256(MAINNET_HISTORY_CODE), bazaar.HISTORY_CODEHASH());
        assertEq(keccak256(HISTORY_CODE), keccak256(MAINNET_HISTORY_CODE));
        assertEq(HISTORY.codehash, bazaar.HISTORY_CODEHASH());
    }

    /// @dev The canonical code answers for ages 1..8191 exactly (the Bazaar's window), reverts at age 0 and
    ///      8192, and answers 0 for a slot never written. Called as the Bazaar calls it.
    function test_check_HistoryAnswersExactlyTheBazaarsWindow() public {
        uint256 now_ = B + 20_000;
        vm.roll(now_);
        uint256[4] memory ages = [uint256(1), 257, 4000, 8191];
        for (uint256 i; i < ages.length; ++i) {
            uint256 n = now_ - ages[i];
            vmb.store(HISTORY, bytes32(n % 8191), _chainHash(n, 7));
            (bool ok, bytes memory r) = HISTORY.staticcall(abi.encode(n));
            assertTrue(ok && r.length == 32);
            assertEq(abi.decode(r, (bytes32)), _chainHash(n, 7));
        }
        (bool ok0,) = HISTORY.staticcall(abi.encode(now_));
        assertTrue(!ok0);
        (bool ok8192,) = HISTORY.staticcall(abi.encode(now_ - 8192));
        assertTrue(!ok8192);
        // a slot nobody wrote reads zero, which seal() treats as "skip"
        (bool okEmpty, bytes memory empty) = HISTORY.staticcall(abi.encode(now_ - 300));
        assertTrue(okEmpty && empty.length == 32 && abi.decode(empty, (bytes32)) == bytes32(0));
    }

    /// @dev No gas limit makes a history-path seal succeed while skipping the kilim: when the lookup is
    ///      starved, the 1/64 the Bazaar keeps cannot pay for the rest of the call, so the whole call fails.
    function test_check_AStarvedHistoryLookupNeverSucceedsWithoutSealing() public {
        _settle(10 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        uint256 sb = bazaar.kilim(id).sealBlock;
        vm.roll(sb + 1 + 1000);
        vmb.store(HISTORY, bytes32(sb % 8191), _chainHash(sb, 0));
        bytes memory call = abi.encodeCall(KilimBazaar.seal, (_list(id)));
        uint256 failed;
        uint256 sealedOk;
        for (uint256 g = 3_000; g <= 40_000; g += 25) {
            uint256 snap = vmb.snapshotState();
            vmb.cool(HISTORY);
            vmb.cool(address(bazaar));
            (bool ok, bytes memory ret) = address(bazaar).call{gas: g}(call);
            if (ok) {
                uint256 count = abi.decode(ret, (uint256));
                assertEq(count, 1); // success always means sealed
                ++sealedOk;
            } else {
                ++failed;
            }
            vmb.revertToState(snap);
        }
        assertTrue(failed > 0 && sealedOk > 0);
    }

    /// @dev sealState says 2 ("sealable now") whenever the age is in the window, even when seal() would skip
    ///      because the lookup answers zero (a slot never written, or a history contract changed by a later
    ///      fork). Informational: a sealer must read KilimSealed, not sealState, to know it worked.
    function test_SL4_SealStateSaysSealableWhenSealWouldSkip() public {
        _settle(10 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 10));
        uint256 sb = bazaar.kilim(id).sealBlock;
        vm.roll(sb + 500); // history path; slot never written in this simulation
        assertEq(bazaar.sealState(id), 2);
        assertEq(bazaar.seal(_list(id)), 0);
        assertEq(bazaar.sealState(id), 2);
    }

    // ------------------------------------------------------------ metadata

    /// @dev Determinism and ERC-4906: the unsealed answer is the same before and after any number of re-arms
    ///      (a re-arm emits no MetadataUpdate and needs none); the seal emits exactly one MetadataUpdate; the
    ///      sealed answer is then the same at any later block and after a transfer.
    function test_check_TokenUriChangesOnlyAtTheSealWhichSignalsIt() public {
        _settle(10 ether);
        vm.roll(B);
        uint256 id = _make(ALICE, _fresh(ALICE, 41));
        bytes32 before = keccak256(bytes(bazaar.tokenURI(id)));
        for (uint256 i; i < 3; ++i) {
            vm.roll(bazaar.kilim(id).sealBlock + 8192);
            vmb.recordLogs();
            bazaar.seal(_list(id));
            VmBazaar.Log[] memory logs = vmb.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].topics[0], SeedRearmed.selector);
            assertEq(keccak256(bytes(bazaar.tokenURI(id))), before);
        }
        uint256 sb = bazaar.kilim(id).sealBlock;
        vm.roll(sb + 1);
        vmb.setBlockhash(sb, _chainHash(sb, 3));
        vmb.recordLogs();
        assertEq(bazaar.seal(_list(id)), 1);
        VmBazaar.Log[] memory sealLogs = vmb.getRecordedLogs();
        uint256 updates;
        for (uint256 i; i < sealLogs.length; ++i) {
            if (sealLogs[i].topics[0] == MetadataUpdate.selector) {
                ++updates;
                assertEq(abi.decode(sealLogs[i].data, (uint256)), id);
            }
        }
        assertEq(updates, 1);
        bytes32 sealedUri = keccak256(bytes(bazaar.tokenURI(id)));
        assertTrue(sealedUri != before);
        vm.roll(sb + 1_000_000);
        vm.prank(ALICE);
        bazaar.transferFrom(ALICE, BOB, id);
        assertEq(keccak256(bytes(bazaar.tokenURI(id))), sealedUri);
    }

    /// @dev S stays inside its JS statement with the largest `top` any uint256 allows (78 digits, a fake
    ///      auction at a 1-wei price): pieceOf parses, carries only the contract's own characters, and the
    ///      sealed tokenURI still passes its exact-length check.
    function test_check_PieceWithTheLargestTopStaysSafe() public {
        FakeAuction fake = new FakeAuction();
        KilimMotifs m = newMotifs(address(fake), TREASURY, 1000);
        KilimOneOfOne o = new KilimOneOfOne(
            address(fake),
            TREASURY,
            m,
            pageFrom(_pageFile("prefix.bin"), pageHead, _pageFile("tail.bin")),
            ONE_OF_ONE_NAME,
            DESCRIPTION,
            ""
        );
        fake.setTokens(m, o);
        fake.setPrice(1);
        KilimBazaar b = new KilimBazaar(KilimAuction(address(fake)), ARTIST, o.tailHash(), BAZAAR_DESCRIPTION, "", "");
        fake.settle(type(uint256).max, 0, 0);
        vm.prank(address(fake));
        m.mintMotifs(ALICE, ALICE, 1, 40);
        vm.prank(ALICE);
        m.setApprovalForAll(address(b), true);
        vm.prank(ALICE);
        uint256 id = b.make(ids(1, 40), ALICE);
        vm.roll(block.number + 2);
        vmb.setBlockhash(block.number - 1, _chainHash(1, 1));
        assertEq(b.seal(_list(id)), 1);
        string memory piece = b.pieceOf(id);
        assertEq(vmb.parseJsonUint(piece, ".top"), type(uint256).max);
        bytes memory p = bytes(piece);
        for (uint256 i; i < p.length; ++i) {
            bytes1 c = p[i];
            bool digit = c >= "0" && c <= "9";
            bool hexLetter = c >= "a" && c <= "f";
            bool punct = c == "{" || c == "}" || c == "[" || c == "]" || c == '"' || c == ":" || c == ",";
            bool key = c == "s" || c == "e" || c == "d" || c == "x" || c == "m" || c == "o" || c == "t"
                || c == "i" || c == "f" || c == "p";
            assertTrue(digit || hexLetter || punct || key);
        }
        bytes memory uri = bytes(b.tokenURI(id));
        assertTrue(_startsWith(uri, 'data:application/json;utf8,{"name":"'));
    }
}
