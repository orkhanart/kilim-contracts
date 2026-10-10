// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";

interface Vm {
    function warp(uint256) external;
    function etch(address, bytes calldata) external;
    function chainId(uint256) external;
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
    /// @dev The bid unit, the auction's MOTIF_PRICE: 0.001 ETH earns one motif.
    uint256 internal constant UNIT = 0.001 ether;
    /// @dev The only reserve the auction accepts, its REGISTRATION_BALANCE: 10 units.
    uint256 internal constant RESERVE = 0.01 ether;
    /// @dev Throwaway registrants are REGISTRANT_BASE, REGISTRANT_BASE + 1, ...
    uint160 internal constant REGISTRANT_BASE = 0x5EED0000;
    /// @dev The motif cap every fixture uses unless a test asks for another.
    uint256 internal constant MOTIF_CAP = 10000;
    uint256 internal constant MOTIF_COUNT = 1024;
    /// @dev SSTORE2 chunks hold at most this many data bytes (EIP-170 less the leading 0x00).
    uint256 internal constant CHUNK = 24_575;
    string internal constant DESCRIPTION = "Stand-in description";
    string internal constant EXTERNAL_URL = "https://kilim.art";
    /// @dev The 1/1's name, as the artist gave it (docs/CONTRACTS.md) and the deploy script pins it.
    string internal constant ONE_OF_ONE_NAME = "The Unwoven Kilim";
    /// @dev The stand-in page: PREFIX is raw JSON up to the animation_url's data scheme, HEAD is the raw
    ///      loader up to the opening quote of GRIDS, and the rest of the loader is stored base64 as TAIL.
    string internal constant PAGE_PREFIX =
        '{"name":"The Unwoven Kilim","description":"stand-in","image":"data:image/png;base64,iVBORw0KGgo=","animation_url":"data:text/html;base64,';
    string internal constant PAGE_HEAD = "<!doctype html><html><body><script>const GRIDS='";
    string internal constant PAGE_REST = "';document.body.textContent=GRIDS.length</script></body></html>";

    /// @dev The stand-in motif store and page, deployed once per test contract, on first use.
    address[] private _gridChunks;
    address private _namesChunk;
    bytes32 private _gridsHash;
    bytes32 private _namesHash;
    KilimOneOfOne.Page private _page;
    bool private _pageDeployed;

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "uint mismatch");
    }

    function assertEq(address a, address b) internal pure {
        require(a == b, "address mismatch");
    }

    function assertEq(bytes32 a, bytes32 b) internal pure {
        require(a == b, "bytes mismatch");
    }

    function assertEq(string memory a, string memory b) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), "string mismatch");
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "assertion failed");
    }

    // ------------------------------------------------------------ the auction and its tokens

    /// @dev A config whose motif collection and 1/1 are freshly deployed, each naming this contract's
    ///      NEXT creation as its minter. So `new KilimAuction(c)` must be the very next contract this
    ///      test creates, exactly as the deploy script orders the three.
    function config() internal returns (KilimAuction.Config memory c) {
        return config(MOTIF_CAP);
    }

    function config(uint256 cap) internal returns (KilimAuction.Config memory c) {
        c = KilimAuction.Config({
            treasury: TREASURY,
            motifs: address(0),
            oneOfOne: address(0),
            startsAt: uint64(block.timestamp + 1 hours),
            duration: 22 hours,
            extensionWindow: 10 minutes,
            incrementBps: 500,
            reservePrice: RESERVE,
            maxMotifsPerBid: 1000
        });
        c = withTokens(c, cap);
    }

    /// @dev Deploys the motif collection and the 1/1 for `c`, in the published order: both take the
    ///      auction's address, predicted as this contract's creation after these two.
    function withTokens(KilimAuction.Config memory c, uint256 cap)
        internal
        returns (KilimAuction.Config memory)
    {
        // The stand-in chunks are created on first use; they must exist before the nonce is read.
        _deployMotifStore();
        standInPage();
        address auction = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        KilimMotifs motifs = newMotifs(auction, c.treasury, cap);
        KilimOneOfOne oneOfOne = newOneOfOne(auction, c.treasury, motifs);
        c.motifs = address(motifs);
        c.oneOfOne = address(oneOfOne);
        return c;
    }

    /// @dev A motif collection over the stand-in grids and names.
    function newMotifs(address minter, address royalty, uint256 cap) internal returns (KilimMotifs) {
        _deployMotifStore();
        return new KilimMotifs(
            minter, royalty, cap, _gridChunks, _gridsHash, _namesChunk, _namesHash, DESCRIPTION, EXTERNAL_URL
        );
    }

    /// @dev A motif collection over the given 32,768 grid bytes and names section.
    function newMotifs(address minter, address royalty, uint256 cap, bytes memory grids, bytes memory names)
        internal
        returns (KilimMotifs)
    {
        return new KilimMotifs(
            minter,
            royalty,
            cap,
            chunked(grids, 767 * 32),
            keccak256(grids),
            sstore2(names),
            keccak256(names),
            DESCRIPTION,
            EXTERNAL_URL
        );
    }

    /// @dev The 1/1 over the stand-in page.
    function newOneOfOne(address minter, address royalty, KilimMotifs motifs)
        internal
        returns (KilimOneOfOne)
    {
        return new KilimOneOfOne(
            minter, royalty, motifs, standInPage(), ONE_OF_ONE_NAME, DESCRIPTION, EXTERNAL_URL
        );
    }

    /// @dev The stand-in page's chunks, deployed on first use.
    function standInPage() internal returns (KilimOneOfOne.Page memory) {
        if (!_pageDeployed) {
            _page = pageFrom(bytes(PAGE_PREFIX), bytes(PAGE_HEAD), bytes(Base64.encode(bytes(PAGE_REST))));
            _pageDeployed = true;
        }
        return _page;
    }

    /// @dev Cuts the three sections into chunks (every chunk but a section's last is full) and deploys them.
    function pageFrom(bytes memory prefix, bytes memory head, bytes memory tail)
        internal
        returns (KilimOneOfOne.Page memory page)
    {
        page.prefixChunks = chunked(prefix, CHUNK);
        page.prefixHash = keccak256(prefix);
        page.headChunks = chunked(head, CHUNK);
        page.headHash = keccak256(head);
        page.tailChunks = chunked(tail, CHUNK);
        page.tailHash = keccak256(tail);
    }

    function _deployMotifStore() private {
        if (_gridChunks.length != 0) return;
        bytes memory grids = standInGrids();
        bytes memory names = standInNames();
        // Grids are cut at 767 x 32 bytes so no grid straddles a chunk: two chunks of 24,544 and 8,224.
        _gridChunks = chunked(grids, 767 * 32);
        _gridsHash = keccak256(grids);
        _namesChunk = sstore2(names);
        _namesHash = keccak256(names);
    }

    // ------------------------------------------------------------ stand-in data

    /// @dev 1,024 arbitrary but fixed grids: motif n's grid is keccak256("kilim stand-in grid", n).
    function standInGrids() internal pure returns (bytes memory out) {
        out = new bytes(MOTIF_COUNT * 32);
        for (uint256 n = 1; n <= MOTIF_COUNT; ++n) {
            bytes32 g = standInGrid(n);
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(sub(n, 1), 32)), g)
            }
        }
    }

    function standInGrid(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("kilim stand-in grid", n));
    }

    /// @dev A names section in the packer's layout: 1,025 big-endian uint16 offsets, then the names.
    ///      Names repeat, as the real ones do (29 meanings across 1,024 motifs).
    function standInNames() internal pure returns (bytes memory) {
        string[] memory names = new string[](MOTIF_COUNT);
        for (uint256 n = 1; n <= MOTIF_COUNT; ++n) {
            names[n - 1] = standInName(n);
        }
        return namesSection(names);
    }

    function standInName(uint256 n) internal pure returns (string memory) {
        return string.concat("Meaning ", vm.toString(n % 29 + 1));
    }

    /// @dev Packs `names` (one per motif, in order) into the offset table and the concatenated names.
    function namesSection(string[] memory names) internal pure returns (bytes memory out) {
        uint256 total;
        for (uint256 i; i < names.length; ++i) {
            total += bytes(names[i]).length;
        }
        out = new bytes(2 * (names.length + 1) + total);
        uint256 offset;
        uint256 pos = 2 * (names.length + 1);
        for (uint256 i; i <= names.length; ++i) {
            out[2 * i] = bytes1(uint8(offset >> 8));
            out[2 * i + 1] = bytes1(uint8(offset));
            if (i == names.length) break;
            bytes memory name = bytes(names[i]);
            for (uint256 k; k < name.length; ++k) {
                out[pos++] = name[k];
            }
            offset += name.length;
        }
    }

    /// @dev One SSTORE2 chunk: creation code 0x61 <len+1> 0x80600a3d393df300 || 0x00 || data, so the
    ///      runtime code is 0x00 || data.
    function sstore2(bytes memory data) internal returns (address chunk) {
        require(data.length != 0 && data.length <= CHUNK, "chunk size");
        bytes memory initcode =
            abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly ("memory-safe") {
            chunk := create(0, add(initcode, 32), mload(initcode))
        }
        require(chunk != address(0), "chunk deployment failed");
    }

    /// @dev Cuts `data` into chunks of `size` bytes (the last one shorter) and deploys each.
    function chunked(bytes memory data, uint256 size) internal returns (address[] memory chunks) {
        uint256 count = (data.length + size - 1) / size;
        chunks = new address[](count);
        for (uint256 k; k < count; ++k) {
            uint256 from = k * size;
            uint256 to = from + size < data.length ? from + size : data.length;
            bytes memory piece = new bytes(to - from);
            assembly ("memory-safe") {
                mcopy(add(piece, 32), add(add(data, 32), from), sub(to, from))
            }
            chunks[k] = sstore2(piece);
        }
    }

    // ------------------------------------------------------------ bidding helpers

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

    /// @dev Mints the next unminted motif ids, as a minter reserving them in order would.
    ///      Calls a view first, so never place it directly after vm.prank or vm.expectRevert.
    function mintNext(KilimMotifs nft, address to, address bidder, uint256 quantity)
        internal
        returns (uint256 first)
    {
        first = 1 + nft.motifsMinted();
        nft.mintMotifs(to, bidder, first, quantity);
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
