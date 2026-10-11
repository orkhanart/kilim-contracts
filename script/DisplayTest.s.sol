// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "./DeployKilim.s.sol";
import {KilimMotifs} from "../src/KilimMotifs.sol";
import {KilimOneOfOne} from "../src/KilimOneOfOne.sol";

/// @notice Mints, as soon as it is built, what a display test needs: the 1/1 and a few motif ids, to `to`.
///         It is the two test collections' minter, so they can mint without an auction.
contract DisplayMinter {
    constructor(KilimMotifs motifs, KilimOneOfOne oneOfOne, address to, uint256 count, uint256 goldenId) {
        oneOfOne.mint(to);
        motifs.mintMotifs(to, to, 1, count);
        if (goldenId > count) motifs.mintMotifs(to, to, goldenId, 1);
    }
}

/// @notice The display test: the two token contracts exactly as mainnet will serve them, minted at once, so
///         marketplaces and indexers can be checked before mainnet (checklists/1-pre-deploy.md, the Sepolia
///         display test). The real auction mints the 1/1 only at settlement, after 100 registrations and a day
///         of bidding, which a rehearsal cannot wait for.
///
///         Over the store already on the chain (runStore first), it deploys KilimMotifs and KilimOneOfOne with
///         the same texts and stored bytes as the launch, but with a small DisplayMinter as their minter instead
///         of the auction. The minter mints the 1/1, motif ids 1..DISPLAY_MOTIFS and the id that shows the
///         golden motif to the sending wallet. Then the script compares both tokenURIs with the packers' goldens.
///         These are throwaway test collections with the launch names: refused on Ethereum mainnet.
///
///   KILIM_DEPLOY_CONFIG=deploy/sepolia.json node scripts/forge.mjs script script/DisplayTest.s.sol \
///     --sig 'display()' --rpc-url "$RPC" --broadcast --slow --sender <wallet> <--ledger or --browser> \
///     --skip-simulation --gas-estimate-multiplier 120
contract DisplayTest is DeployKilim {
    uint256 public constant DISPLAY_MOTIFS = 8;

    struct Display {
        KilimMotifs motifs;
        KilimOneOfOne oneOfOne;
        address minter;
        uint256 goldenId;
    }

    function display() external {
        displayFrom(loadConfig(vm.envString("KILIM_DEPLOY_CONFIG")), msg.sender);
    }

    /// @dev Three creations from `sender`: the motif collection at nonce n, the 1/1 at n + 1, both naming the
    ///      DisplayMinter at n + 2, which mints in its constructor.
    function displayFrom(Config memory c, address sender) public returns (Display memory d) {
        if (block.chainid == MAINNET_CHAIN_ID) revert Refused("the display test is not for mainnet");
        Store memory s = loadStore(c);
        _requireStored(s);
        if (c.hasExpected) _requireExpected(c, s);
        uint256 n = vm.getNonce(sender);
        d.minter = vm.computeCreateAddress(sender, n + 2);
        vm.startBroadcast(sender);
        d.motifs = new KilimMotifs(
            d.minter,
            c.auction.treasury,
            c.motifCap,
            s.grids.addresses,
            s.grids.hash,
            s.names.addresses[0],
            s.names.hash,
            c.collectionDescription,
            c.collectionExternalUrl
        );
        d.oneOfOne = new KilimOneOfOne(
            d.minter,
            c.auction.treasury,
            d.motifs,
            _page(s),
            c.oneOfOneName,
            c.oneOfOneDescription,
            c.oneOfOneExternalUrl
        );
        d.goldenId = _idShowing(d.motifs, vm.parseJsonUint(s.motifManifest, ".golden.motif"));
        DisplayMinter m = new DisplayMinter(d.motifs, d.oneOfOne, sender, DISPLAY_MOTIFS, d.goldenId);
        vm.stopBroadcast();
        if (address(m) != d.minter) revert Refused("display minter address");
        if (d.oneOfOne.ownerOf(1) != sender || d.motifs.ownerOf(d.goldenId) != sender) {
            revert Refused("display mint");
        }
        if (
            sha256(bytes(d.motifs.tokenURI(d.goldenId)))
                != vm.parseJsonBytes32(s.motifManifest, ".golden.tokenURI.sha256")
        ) revert Refused("motif tokenURI differs from golden");
        if (
            sha256(bytes(d.oneOfOne.tokenURI(1)))
                != vm.parseJsonBytes32(s.pageManifest, ".golden.tokenURI.sha256")
        ) revert Refused("1/1 tokenURI differs from golden");
        _log(string.concat("display KilimMotifs   ", vm.toString(address(d.motifs))));
        _log(string.concat("display KilimOneOfOne ", vm.toString(address(d.oneOfOne))));
        _log(
            string.concat(
                "display minted the 1/1 and motif ids 1..8 and ",
                vm.toString(d.goldenId),
                " to ",
                vm.toString(sender)
            )
        );
    }
}
