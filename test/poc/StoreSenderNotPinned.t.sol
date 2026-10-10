// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DeployKilim} from "../../script/DeployKilim.s.sol";
import {TestBase} from "../TestBase.sol";

interface VmPoc {
    function readFile(string calldata) external view returns (string memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function getNonce(address) external view returns (uint64);
    function chainId(uint256) external;
}

/// @notice PoC for the "deploy" review finding on script/DeployKilim.s.sol (skeptic pass): the store
///         phase broadcasts from the config's `deployer` (`vm.startBroadcast(c.deployer)`), not from
///         forge's --sender, and `_requireLaunchSettings` runs only in the contracts phase. So on chain 1
///         a store-only config whose deployer is any funded key is accepted, and the same config is
///         refused for the contracts. That is the way out of the mismatch with 2-deploy.md ("--sender
///         <any funded key>"), and it means two configs on deploy day: one for the store, the signed-off
///         one for the contracts.
///
///         Reads the packed stores, like test/DeployKilim.t.sol.
contract StoreSenderNotPinnedTest is TestBase {
    VmPoc internal constant vmp = VmPoc(address(uint160(uint256(keccak256("hevm cheat code")))));
    string internal constant GLYPH_STORE = "../onchain/build-glyphs";
    string internal constant PAGE_STORE = "../onchain/build-page";
    address internal constant ARTIST = 0xd6647Eeec0c8D810C546f2ab8e025D4664d833Ac;
    address internal constant FUNDED_KEY = address(0xF00D);

    DeployKilim internal script;

    function setUp() public {
        script = new DeployKilim();
        vm.warp(1_800_000_000);
    }

    function _launchConfig(address deployer) internal view returns (DeployKilim.Config memory c) {
        c.chainId = 1;
        c.deployer = deployer;
        c.deployerNonce = vmp.getNonce(deployer);
        c.minLeadSeconds = 1 days;
        c.glyphStore = GLYPH_STORE;
        c.pageStore = PAGE_STORE;
        c.auction.treasury = ARTIST;
        c.auction.startsAt = uint64(block.timestamp + 2 days);
        c.auction.duration = script.LAUNCH_DURATION();
        c.auction.extensionWindow = script.LAUNCH_EXTENSION_WINDOW();
        c.auction.incrementBps = script.LAUNCH_INCREMENT_BPS();
        c.auction.reservePrice = script.LAUNCH_RESERVE_PRICE();
        c.auction.maxGlyphsPerBid = script.LAUNCH_MAX_GLYPHS_PER_BID();
        c.glyphCap = script.LAUNCH_GLYPH_CAP();
        string memory g = vmp.readFile(string.concat(GLYPH_STORE, "/manifest.json"));
        string memory pg = vmp.readFile(string.concat(PAGE_STORE, "/manifest.json"));
        c.collectionDescription = vmp.parseJsonString(g, ".description");
        c.collectionExternalUrl = EXTERNAL_URL;
        c.oneOfOneName = vmp.parseJsonString(pg, ".name");
        c.oneOfOneDescription = vmp.parseJsonString(pg, ".description");
        c.oneOfOneExternalUrl = vmp.parseJsonString(pg, ".externalUrl");
    }

    /// @dev Chain 1, config deployer = some funded key, not the artist: the store goes through and every
    ///      chunk transaction is the config deployer's (its nonce moves by one per chunk); the artist's
    ///      nonce does not move. The contracts phase with that config is refused on the deployer.
    function testMainnetStoreAcceptsAnyConfigDeployerAndSendsFromIt() public {
        vmp.chainId(1);
        DeployKilim.Config memory c = _launchConfig(FUNDED_KEY);
        uint64 keyNonce = vmp.getNonce(FUNDED_KEY);
        uint64 artistNonce = vmp.getNonce(ARTIST);
        DeployKilim.Store memory s = script.deployStore(c);
        uint256 chunks = s.grids.chunks.length + s.names.chunks.length + s.prefix.chunks.length
            + s.head.chunks.length + s.tail.chunks.length;
        assertEq(chunks, 38);
        assertEq(vmp.getNonce(FUNDED_KEY), keyNonce + chunks); // the store is sent by the config's deployer
        assertEq(vmp.getNonce(ARTIST), artistNonce);
        vm.expectRevert(
            abi.encodeWithSelector(DeployKilim.Refused.selector, "mainnet launch value: deployer")
        );
        script.deployContracts(c);
    }

    /// @dev The other way out: the store from the artist's wallet. Then the nonce the contracts phase
    ///      needs is the one after the store, and a nonce read (and published) before the store is
    ///      refused.
    function testStoreFromTheArtistSpendsThePublishedNonce() public {
        vmp.chainId(1);
        DeployKilim.Config memory c = _launchConfig(ARTIST);
        uint64 published = vmp.getNonce(ARTIST); // read before the store went up
        script.deployStore(c);
        assertEq(vmp.getNonce(ARTIST), published + 38);
        c.deployerNonce = published;
        vm.expectRevert(abi.encodeWithSelector(DeployKilim.Refused.selector, "deployer nonce"));
        script.deployContracts(c);
        c.deployerNonce = published + 38;
        DeployKilim.Deployed memory d = script.deployContracts(c);
        assertEq(address(d.glyphs), vm.computeCreateAddress(ARTIST, published + 38));
    }
}
