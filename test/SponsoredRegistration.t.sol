// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TestBase} from "./TestBase.sol";
import {KilimAuction} from "../src/KilimAuction.sol";
import {EnglishAuction} from "../src/auction/EnglishAuction.sol";

interface SigningVm {
    function addr(uint256) external returns (address);
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function chainId(uint256) external;
}

contract RegistrationWallet {
    bytes32 public accepted;

    function allow(bytes32 digest) external {
        accepted = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == accepted ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract SponsoredRegistrationTest is TestBase {
    SigningVm private signer = SigningVm(address(vm));
    KilimAuction private auction;
    address private user;
    uint256 private constant KEY = 123456;
    uint256 private deadline;

    function setUp() public {
        KilimAuction.Config memory c = config();
        auction = new KilimAuction(c);
        vm.warp(c.startsAt);
        user = signer.addr(KEY);
        vm.deal(user, 0.01 ether);
        deadline = block.timestamp + 15 minutes;
    }

    function signature(bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = signer.sign(KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function testSponsorRegistersSignerWithoutSpendingSignerFundsOrStarting() public {
        bytes memory sig = signature(auction.registrationDigest(user, deadline));
        vm.prank(BOB);
        auction.registerFor(user, deadline, sig);
        assertTrue(auction.registered(user));
        assertTrue(!auction.registered(BOB));
        assertEq(user.balance, 0.01 ether);
        assertEq(auction.registrationCount(), 1);
        assertEq(auction.endsAt(), 0);
        assertEq(auction.motifCredits(user), 0);
        assertEq(address(auction).balance, 0);
        vm.expectRevert(EnglishAuction.AlreadyRegistered.selector);
        auction.registerFor(user, deadline, sig);
    }

    function testDirectAndSponsoredRegistrationShareReplayGuard() public {
        bytes memory sig = signature(auction.registrationDigest(user, deadline));
        vm.prank(user);
        auction.register();
        vm.expectRevert(EnglishAuction.AlreadyRegistered.selector);
        auction.registerFor(user, deadline, sig);
    }

    function testSignatureCannotChangeWalletOrDeadline() public {
        bytes memory sig = signature(auction.registrationDigest(user, deadline));
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        auction.registerFor(BOB, deadline, sig);
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        auction.registerFor(user, deadline + 1, sig);
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        auction.registerFor(address(0), deadline, sig);
    }

    function testExpiryAndBalanceAreCheckedAtExecution() public {
        bytes memory sig = signature(auction.registrationDigest(user, deadline));
        vm.deal(user, 0.01 ether - 1);
        vm.expectRevert(EnglishAuction.InsufficientRegistrationBalance.selector);
        auction.registerFor(user, deadline, sig);
        vm.deal(user, 0.01 ether);
        vm.warp(deadline + 1);
        vm.expectRevert(EnglishAuction.RegistrationSignatureExpired.selector);
        auction.registerFor(user, deadline, sig);
    }

    function testSignatureCannotReplayAcrossChainsOrAuctions() public {
        bytes memory sig = signature(auction.registrationDigest(user, deadline));
        uint256 original = block.chainid;
        signer.chainId(original + 1);
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        auction.registerFor(user, deadline, sig);
        signer.chainId(original);
        KilimAuction.Config memory c = config();
        KilimAuction other = new KilimAuction(c);
        vm.warp(c.startsAt);
        // Original deadline may expire by then; use a fresh signature for the original auction.
        deadline = block.timestamp + 15 minutes;
        sig = signature(auction.registrationDigest(user, deadline));
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        other.registerFor(user, deadline, sig);
    }

    function testERC1271WalletAndRevokedSignature() public {
        RegistrationWallet wallet = new RegistrationWallet();
        vm.deal(address(wallet), 0.01 ether);
        bytes32 digest = auction.registrationDigest(address(wallet), deadline);
        vm.expectRevert(EnglishAuction.InvalidRegistrationSignature.selector);
        auction.registerFor(address(wallet), deadline, hex"abcd");
        wallet.allow(digest);
        auction.registerFor(address(wallet), deadline, hex"abcd");
        assertTrue(auction.registered(address(wallet)));
    }

    function testHundredthSponsoredRegistrationOnlyUnlocks() public {
        _registerWallets(auction, 99);
        auction.registerFor(user, deadline, signature(auction.registrationDigest(user, deadline)));
        assertEq(auction.registrationCount(), 100);
        assertEq(auction.endsAt(), 0);
        assertEq(auction.motifCredits(user), 0);
        vm.deal(BOB, 0.01 ether);
        vm.prank(BOB);
        auction.bid{value: 0.01 ether}(0.01 ether, 10, 0);
        assertEq(auction.highestBidder(), BOB);
    }

    /// @dev Registration opens at startsAt and not one second earlier, on both paths (audit F-16).
    function testRegistrationIsClosedBeforeStartsAt() public {
        KilimAuction.Config memory c = config();
        KilimAuction early = new KilimAuction(c);
        uint256 late = uint256(c.startsAt) + 15 minutes;
        bytes memory sig = signature(early.registrationDigest(user, late));
        vm.warp(uint256(c.startsAt) - 1);
        vm.expectRevert(EnglishAuction.RegistrationClosed.selector);
        vm.prank(user);
        early.register();
        vm.expectRevert(EnglishAuction.RegistrationClosed.selector);
        early.registerFor(user, late, sig);
        assertEq(early.registrationCount(), 0);
        assertTrue(!early.registered(user));
        vm.warp(c.startsAt);
        early.registerFor(user, late, sig);
        assertTrue(early.registered(user));
        assertEq(early.registrationCount(), 1);
    }

    /// @dev The treasury cannot take a registration slot, itself or through a sponsor (audit F-16).
    function testTreasuryCannotRegister() public {
        KilimAuction.Config memory c = config();
        c.treasury = user;
        KilimAuction own = new KilimAuction(c);
        uint256 late = uint256(c.startsAt) + 15 minutes;
        bytes memory sig = signature(own.registrationDigest(user, late));
        vm.warp(c.startsAt);
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(user);
        own.register();
        vm.expectRevert(EnglishAuction.TreasuryCannotBid.selector);
        vm.prank(BOB);
        own.registerFor(user, late, sig);
        assertEq(own.registrationCount(), 0);
        assertTrue(!own.registered(user));
        // The same wallet registers on an auction where it is not the treasury.
        vm.prank(user);
        auction.register();
        assertTrue(auction.registered(user));
    }
}
