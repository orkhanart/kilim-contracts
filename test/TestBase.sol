// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KilimAuction} from "../src/KilimAuction.sol";
import {Kilim} from "../src/Kilim.sol";
import {MockRenderer} from "./mocks/MockRenderer.sol";

interface Vm {
    function warp(uint256) external;
    function roll(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectPartialRevert(bytes4) external;
    function deal(address, uint256) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function expectEmit() external;
    function toString(uint256) external pure returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonBool(string calldata, string calldata) external pure returns (bool);
    function getNonce(address) external view returns (uint64);
    function computeCreateAddress(address, uint256) external pure returns (address);
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant TREASURY = address(0x7777);
    address internal constant PAGE_OWNER = address(0x9999);
    /// @dev The bid unit, the auction's SYMBOL_PRICE: 0.001 ETH earns one symbol.
    uint256 internal constant UNIT = 0.001 ether;
    /// @dev The only reserve the auction accepts, its REGISTRATION_BALANCE: 10 units.
    uint256 internal constant RESERVE = 0.01 ether;
    /// @dev Throwaway registrants are REGISTRANT_BASE, REGISTRANT_BASE + 1, ...
    uint160 internal constant REGISTRANT_BASE = 0x5EED0000;
    bytes32 internal constant INK = "flat/ink";
    bytes32 internal constant INDIGO = "flat/indigo";
    bytes32 internal constant VERMILION = "flat/vermilion";
    /// @dev The renderer every unit fixture wires in: 812 motifs, a test geometry hash.
    MockRenderer internal mockRenderer = new MockRenderer(812, keccak256("test geometry"));

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "uint mismatch");
    }

    function assertEq(address a, address b) internal pure {
        require(a == b, "address mismatch");
    }

    function assertEq(bytes32 a, bytes32 b) internal pure {
        require(a == b, "bytes mismatch");
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "assertion failed");
    }

    function config() internal view returns (KilimAuction.Config memory c) {
        c = KilimAuction.Config({
            treasury: TREASURY,
            collectionOwner: PAGE_OWNER,
            startsAt: uint64(block.timestamp + 1 hours),
            duration: 22 hours,
            extensionWindow: 10 minutes,
            incrementBps: 500,
            reservePrice: RESERVE,
            symbolCap: 10000,
            maxSymbolsPerBid: 1000,
            motifCount: 812,
            maxCells: 256,
            geometryHash: mockRenderer.geometryHash(),
            rendererHash: address(mockRenderer).codehash,
            renderer: address(mockRenderer)
        });
    }

    /// @dev The i-th throwaway registrant. No code, and distinct from ALICE, BOB, CAROL and the treasury.
    function registrant(uint256 i) internal pure returns (address) {
        return address(REGISTRANT_BASE + uint160(i));
    }

    /// @dev Registers `count` more throwaway wallets, each funded with exactly the registration balance.
    ///      The time must already be at or past startsAt. Calls may be repeated: each one continues
    ///      after the wallets already registered.
    function _registerWallets(KilimAuction auction, uint256 count) internal {
        uint256 first = auction.registrationCount();
        for (uint256 i = first; i < first + count; ++i) {
            address wallet = registrant(i);
            vm.deal(wallet, RESERVE);
            vm.prank(wallet);
            auction.register();
        }
    }

    /// @dev Warps to startsAt if it is still ahead, then fills every remaining registration slot with
    ///      throwaway wallets. Afterwards any wallet but the treasury can bid; no bid has been placed.
    function _openBidding(KilimAuction auction) internal {
        if (block.timestamp < auction.startsAt()) vm.warp(auction.startsAt());
        _registerWallets(auction, auction.REGISTRATION_TARGET() - auction.registrationCount());
    }

    /// @dev Sets `who`'s ETH balance to exactly `amount`.
    function _fund(address who, uint256 amount) internal {
        vm.deal(who, amount);
    }

    /// @dev `bidder` bids `amount` wei, paid in full, accepting any reward. The bidder must hold it.
    ///      Reads nothing first, so it may directly follow vm.expectRevert.
    function _bid(KilimAuction auction, address bidder, uint256 amount) internal {
        vm.prank(bidder);
        auction.bid{value: amount}(amount, 0, 0);
    }

    /// @dev One of the three canonical appearances, picked by `seed`.
    function appearanceOf(uint256 seed) internal pure returns (bytes32) {
        uint256 k = seed % 3;
        return k == 0 ? INK : k == 1 ? INDIGO : VERMILION;
    }

    /// @dev A collection wired to a mock renderer with `motifs` motifs, as the auction would create it.
    function newKilim(
        address minter,
        address pageOwner,
        address royalty,
        uint256 cap,
        uint16 motifs,
        uint16 cells
    ) internal returns (Kilim) {
        MockRenderer r = motifs == 812 ? mockRenderer : new MockRenderer(motifs, keccak256("test geometry"));
        return
            new Kilim(
                minter, pageOwner, royalty, cap, motifs, cells, r.geometryHash(), address(r).codehash, r
            );
    }

    /// @dev Mints the next unminted symbol IDs, as a minter reserving them in order would.
    ///      Calls a view first, so never place it directly after vm.prank or vm.expectRevert.
    function mintNext(Kilim nft, address to, address bidder, uint256 quantity)
        internal
        returns (uint256 first)
    {
        first = nft.FIRST_SYMBOL_ID() + nft.symbolsMinted();
        nft.mintSymbols(to, bidder, first, quantity);
    }

    function ids(uint256 start, uint256 count) internal pure returns (uint256[] memory result) {
        result = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            result[i] = start + i;
        }
    }
}

/// @dev Explicit empty optional getters keep Foundry's invariant target discovery deterministic.
abstract contract InvariantBase is TestBase {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    struct FuzzArtifactSelector {
        string artifact;
        bytes4[] selectors;
    }

    struct FuzzInterface {
        address addr;
        string[] artifacts;
    }

    function targetArtifactSelectors() public pure returns (FuzzArtifactSelector[] memory) {
        return new FuzzArtifactSelector[](0);
    }

    function targetArtifacts() public pure returns (string[] memory) {
        return new string[](0);
    }

    function excludeArtifacts() public pure returns (string[] memory) {
        return new string[](0);
    }

    function targetSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeSenders() public pure returns (address[] memory) {
        return new address[](0);
    }

    function excludeContracts() public pure returns (address[] memory) {
        return new address[](0);
    }

    function targetInterfaces() public pure returns (FuzzInterface[] memory) {
        return new FuzzInterface[](0);
    }

    function targetSelectors() public pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }

    function excludeSelectors() public pure returns (FuzzSelector[] memory) {
        return new FuzzSelector[](0);
    }
}
