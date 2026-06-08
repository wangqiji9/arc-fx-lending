// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test fee-on-transfer ERC20: deducts 1% on transfer, recipient receives 99%.
/// @dev Used to verify that LendingPool._pull's balance-difference check rejects such tokens.
contract MockFeeToken is ERC20 {
    uint8 private immutable _dec;
    uint256 public constant FEE_BPS = 100; // 1% fee

    constructor(uint8 decimals_) ERC20("FeeToken", "FEE") {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Burns 1% fee first, then delivers the remaining 99% to the recipient,
    ///      so the actual amount received is less than `amount`.
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount * FEE_BPS / 10_000;
            super._update(from, address(0), fee);       // burn fee
            super._update(from, to, amount - fee);      // deliver rest
        } else {
            super._update(from, to, amount);
        }
    }
}
