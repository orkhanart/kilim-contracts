// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSD is ERC20 {
    uint8 private immutable _decimals;
    uint16 public feeBps;
    /// @dev A fee on transfer() only (payouts), leaving deposits through transferFrom whole.
    uint16 public transferFeeBps;
    bool private _inTransfer;
    bool public returnsFalse;
    address public blockedRecipient;
    address public hookTarget;
    bytes public hookData;
    bool public callbackSucceeded;

    constructor(uint8 decimals_) ERC20("Mock USD", "MUSD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint16 bps) external {
        feeBps = bps;
    }

    function setFeeOnTransferOnly(uint16 bps) external {
        transferFeeBps = bps;
    }

    function setReturnsFalse(bool flag) external {
        returnsFalse = flag;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (returnsFalse) return false;
        _inTransfer = true;
        bool result = super.transfer(to, amount);
        _inTransfer = false;
        _callback();
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (returnsFalse) return false;
        bool result = super.transferFrom(from, to, amount);
        _callback();
        return result;
    }

    function _callback() private {
        if (hookTarget != address(0)) {
            (callbackSucceeded,) = hookTarget.call(hookData);
        }
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != blockedRecipient || to == address(0), "recipient blocked");
        uint256 bps = feeBps != 0 ? feeBps : (_inTransfer ? transferFeeBps : 0);
        if (from != address(0) && to != address(0) && bps != 0) {
            uint256 fee = amount * bps / 10000;
            super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
        } else {
            super._update(from, to, amount);
        }
    }
}
