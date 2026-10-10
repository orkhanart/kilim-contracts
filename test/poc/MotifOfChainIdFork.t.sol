// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimMotifs} from "../../src/KilimMotifs.sol";
import {TestBase} from "../TestBase.sol";

interface VmChain {
    function chainId(uint256) external;
}

/// @dev Review PoC: `motifOf` hashes `block.chainid` at call time (docs/CONTRACTS.md line 43), so a chain
///      that changes its id after the auction shows other motifs for the same, still-owned tokens. Measures
///      how much re-rolls, shows it is the live id and not state (restoring the id restores the motifs),
///      and that a chain id captured at construction would not move. Whether that is wanted is a design
///      question the test does not answer: the ecosystem binds to the live id on purpose (EIP-712).
contract MotifOfChainIdForkPoC is TestBase {
    VmChain internal constant vmc = VmChain(address(uint160(uint256(keccak256("hevm cheat code")))));
    KilimMotifs internal nft;
    uint256 internal homeChain;

    function setUp() public {
        nft = newMotifs(address(this), TREASURY, MOTIF_CAP);
        homeChain = block.chainid;
        nft.mintMotifs(ALICE, ALICE, 1, 64);
    }

    event log_named_uint(string key, uint256 val);

    /// @dev Another chain id, ownership unchanged, the motif (and so the image) of almost every token changed.
    function testChainIdChangeRerollsTheMotifsButNotTheOwners() public {
        uint16[64] memory before;
        bytes32[64] memory uriBefore;
        for (uint256 id = 1; id <= 64; ++id) {
            before[id - 1] = nft.motifOf(id);
            uriBefore[id - 1] = keccak256(bytes(nft.tokenURI(id)));
        }
        vmc.chainId(homeChain + 1);
        uint256 moved;
        uint256 uriMoved;
        for (uint256 id = 1; id <= 64; ++id) {
            assertEq(nft.ownerOf(id), ALICE);
            if (nft.motifOf(id) != before[id - 1]) ++moved;
            if (keccak256(bytes(nft.tokenURI(id))) != uriBefore[id - 1]) ++uriMoved;
        }
        emit log_named_uint("minted tokens", 64);
        emit log_named_uint("motif changed", moved);
        emit log_named_uint("tokenURI changed", uriMoved);
        assertTrue(moved > 0);
        assertEq(moved, uriMoved);
        // The quote for every id in the cap moves the same way (expected 1023/1024 of them).
        vmc.chainId(homeChain);
        uint256 quoteMoved;
        for (uint256 id = 1; id <= MOTIF_CAP; ++id) {
            uint16 q = nft.motifOf(id);
            vmc.chainId(homeChain + 1);
            if (nft.motifOf(id) != q) ++quoteMoved;
            vmc.chainId(homeChain);
        }
        emit log_named_uint("ids in cap", MOTIF_CAP);
        emit log_named_uint("quotes changed", quoteMoved);
        assertTrue(quoteMoved * 1000 > MOTIF_CAP * 990);
    }

    /// @dev Nothing is stored: the motifs follow the live chain id and come back with it.
    function testRestoringTheChainIdRestoresTheMotifs() public {
        uint16 g = nft.motifOf(1);
        bytes32 uri = keccak256(bytes(nft.tokenURI(1)));
        vmc.chainId(homeChain + 1);
        vmc.chainId(homeChain);
        assertEq(nft.motifOf(1), g);
        assertEq(keccak256(bytes(nft.tokenURI(1))), uri);
    }

    /// @dev The suggested alternative: a chain id captured at construction. Same formula, does not move.
    function testAChainIdCapturedAtConstructionWouldNotMove() public {
        ChainPinned pinned = new ChainPinned(address(nft));
        assertEq(pinned.CHAIN_ID(), homeChain);
        uint16[64] memory before;
        for (uint256 id = 1; id <= 64; ++id) {
            // On the deployment chain both derivations agree.
            before[id - 1] = pinned.motifOf(id);
            assertEq(before[id - 1], nft.motifOf(id));
        }
        vmc.chainId(homeChain + 1);
        for (uint256 id = 1; id <= 64; ++id) {
            assertEq(pinned.motifOf(id), before[id - 1]);
        }
    }
}

/// @dev `motifOf` with the chain id pinned at construction, computed for the collection's address so it can
///      be compared with the live derivation on the deployment chain.
contract ChainPinned {
    uint256 public immutable CHAIN_ID = block.chainid;
    address internal immutable collection;

    constructor(address collection_) {
        collection = collection_;
    }

    function motifOf(uint256 id) external view returns (uint16) {
        return uint16(uint256(keccak256(abi.encode(CHAIN_ID, collection, id))) % 1024 + 1);
    }
}
