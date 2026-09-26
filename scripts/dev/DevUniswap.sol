// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// LOCAL DEVELOPMENT ONLY. Never deployed anywhere but a local anvil chain.
// A stand-in for Uniswap's SwapRouter02 and QuoterV2 with the same selectors, so the site's
// pay-with-ETH path (multicall(deadline, [exactOutputSingle, refundETH])) runs end to end
// against the local MockUSD. It sells MockUSD at a fixed price by minting it.
// Compiled by scripts/dev/deploy.mjs with the pinned solc; forge does not build this folder.

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract DevSwapRouter02 {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    address public immutable WETH9 = address(uint160(uint256(keccak256("kilim.dev.weth"))));
    address public immutable usdc;
    uint256 public immutable usdPerEth;
    /// @dev ETH taken by swaps. refundETH returns only what is above it.
    uint256 public ethReserve;

    constructor(address usdc_, uint256 usdPerEth_) {
        usdc = usdc_;
        usdPerEth = usdPerEth_;
    }

    function quote(uint256 amountOut, uint24 fee) public view returns (uint256) {
        uint256 numerator = amountOut * 1e12 * (1e6 + uint256(fee));
        uint256 denominator = usdPerEth * 1e6;
        return (numerator + denominator - 1) / denominator;
    }

    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results) {
        require(block.timestamp <= deadline, "Transaction too old");
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            results[i] = result;
        }
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
        require(params.tokenIn == WETH9 && params.tokenOut == usdc, "Unsupported pair");
        amountIn = quote(params.amountOut, params.fee);
        require(amountIn <= params.amountInMaximum, "Too much requested");
        require(address(this).balance >= ethReserve + amountIn, "STF");
        ethReserve += amountIn;
        IMintable(usdc).mint(params.recipient, params.amountOut);
    }

    function refundETH() external payable {
        uint256 spare = address(this).balance - ethReserve;
        if (spare > 0) {
            (bool ok,) = msg.sender.call{value: spare}("");
            require(ok, "STE");
        }
    }
}

contract DevQuoterV2 {
    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    DevSwapRouter02 public immutable router;

    constructor(DevSwapRouter02 router_) {
        router = router_;
    }

    function WETH9() external view returns (address) {
        return router.WETH9();
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams calldata params)
        external
        view
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        require(params.tokenIn == router.WETH9() && params.tokenOut == router.usdc(), "Unsupported pair");
        return (router.quote(params.amount, params.fee), 0, 0, 90000);
    }
}
