// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interfaces/IERC20Burnable.sol";
import "./interfaces/IWETH9.sol";
import "./lib/OracleLibrary.sol";
import "./lib/TickMath.sol";
import "./lib/constants.sol";

/// @title LegendX Buy & Burn Contract
contract LegendXBuyBurn is Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Burnable;

    // -------------------------- STATE VARIABLES -------------------------- //

    /// @notice The total amount of TitanX tokens used in Buy & Burn to date.
    uint256 public totalTitanXUsed;
    /// @notice The total amount of LegendX tokens burned to date.
    uint256 public totalLgndxBurned;

    /// @notice Incentive fee amount, measured in basis points (100 bps = 1%).
    uint16 public incentiveFeeBps = 30;
    /// @notice The maximum amount of TitanX that can be swapped per Buy & Burn.
    uint256 public capPerSwapTitanX = 500_000_000 ether;
    /// @notice The maximum amount of X28 that can be swapped per Buy & Burn.
    uint256 public capPerSwapX28 = 2_000_000_000 ether;
    /// @notice The maximum amount of ETH that can be swapped in a single call.
    uint256 public capPerSwapEth = 1 ether;
    /// @notice Cooldown for Buy & Burns in seconds.
    uint32 public buyBurnInterval = 8 hours;
    /// @notice Time of the last Buy & Burn in seconds.
    uint256 public lastBuyBurn;
    /// @notice Time of the last ETH swap in seconds.
    uint256 public lastEthSwap;
    /// @notice Time used for TWAP calculation
    uint32 public secondsAgo = 5 * 60;
    /// @notice Allowed deviation of the minAmountOut from historical price for TitanX -> LegendX swap.
    uint32 public titanXDeviation = 2000;
    /// @notice Allowed deviation of the minAmountOut from historical price for X28 -> TitanX swap.
    uint32 public x28Deviation = 1000;
    /// @notice Allowed deviation of the minAmountOut from historical price for ETH -> TitanX swap.
    uint32 public ethDeviation = 1000;

    // ------------------------------- EVENTS ------------------------------ //

    event BuyBurn();
    event EthSwap();

    // ------------------------------- ERRORS ------------------------------ //

    error Prohibited();
    error Cooldown();
    error NoAllocation();
    error ZeroInput();
    error TWAP();

    // ------------------------------ MODIFIERS ---------------------------- //

    modifier originCheck() {
        if (address(msg.sender).code.length != 0 || msg.sender != tx.origin) revert Prohibited();
        _;
    }

    // ----------------------------- CONSTRUCTOR --------------------------- //

    constructor(address _owner) Ownable(_owner) {}

    // --------------------------- PUBLIC FUNCTIONS ------------------------ //

    receive() external payable {}

    fallback() external payable {}

    /// @notice Buys and burns LegendX tokens using TitanX and X28 balance.
    /// @param minLgndxAmount The minimum amount out for TitanX -> LegendX swap.
    /// @param minTitanXAmount The minimum amount out for the X28 -> TitanX swap (if applicalbe).
    /// @param deadline The deadline for the swaps.
    function buyAndBurn(uint256 minLgndxAmount, uint256 minTitanXAmount, uint256 deadline) external originCheck {
        if (block.timestamp < lastBuyBurn + buyBurnInterval) revert Cooldown();

        lastBuyBurn = block.timestamp;
        uint256 titanXBalance = IERC20(TITANX).balanceOf(address(this));
        if (titanXBalance < capPerSwapTitanX) {
            titanXBalance = _handleX28BalanceCheck(titanXBalance, minTitanXAmount, deadline);
        }
        if (titanXBalance == 0) revert NoAllocation();
        uint256 amountToSwap = titanXBalance > capPerSwapTitanX ? capPerSwapTitanX : titanXBalance;
        totalTitanXUsed += amountToSwap;
        amountToSwap = _processIncentiveFee(amountToSwap);
        _swapTitanXtoLegendX(amountToSwap, minLgndxAmount, deadline);
        burnLegendX();
        emit BuyBurn();
    }

    function swapEthforTitanX(uint256 minTitanXAmount, uint256 deadline) external originCheck {
        if (block.timestamp < lastEthSwap + buyBurnInterval) revert Cooldown();

        lastEthSwap = block.timestamp;
        uint256 ethBalance = address(this).balance;
        if (ethBalance == 0) revert NoAllocation();
        uint256 amountToSwap = ethBalance > capPerSwapEth ? capPerSwapEth : ethBalance;
        _swapEthforTitanX(amountToSwap, minTitanXAmount, deadline);
        emit EthSwap();
    }

    /// @notice Burns all LegendX tokens owned by Buy & Burn contractt.
    function burnLegendX() public {
        IERC20Burnable lgndx = IERC20Burnable(LGNDX);
        uint256 amountToBurn = lgndx.balanceOf(address(this));
        lgndx.burn(amountToBurn);
        totalLgndxBurned += amountToBurn;
    }

    // ----------------------- ADMINISTRATIVE FUNCTIONS -------------------- //

    /// @notice Sets the incentive fee basis points (bps) for Buy & Burns.
    /// @param bps The incentive fee in basis points (30 - 500), (100 bps = 1%).
    function setIncentiveFee(uint16 bps) external onlyOwner {
        if (bps < 30 || bps > 500) revert Prohibited();
        incentiveFeeBps = bps;
    }

    /// @notice Sets the Buy & Burn interval.
    /// @param limit The new interval in seconds.
    function setBuyBurnInterval(uint32 limit) external onlyOwner {
        if (limit == 0) revert Prohibited();
        buyBurnInterval = limit;
    }

    /// @notice Sets the cap per swap for TitanX -> LegendX swaps.
    /// @param limit The new cap limit in WEI applied to TitanX balance.
    function setCapPerSwapTitanX(uint256 limit) external onlyOwner {
        capPerSwapTitanX = limit;
    }

    /// @notice Sets the cap per swap for X28 -> TitanX swaps.
    /// @param limit The new cap limit in WEI applied to X28 balance.
    function setCapPerSwapX28(uint256 limit) external onlyOwner {
        capPerSwapX28 = limit;
    }

    /// @notice Sets the cap per swap for ETH -> TitanX swaps.
    /// @param limit The new cap limit in WEI applied to ETH balance.
    function setCapPerSwapEth(uint256 limit) external onlyOwner {
        capPerSwapEth = limit;
    }

    /// @notice Sets the number of seconds to look back for TWAP price calculations.
    /// @param limit The number of seconds to use for TWAP price lookback.
    function setSecondsAgo(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        secondsAgo = limit;
    }

    /// @notice Sets the allowed price deviation for TWAP checks during TitanX -> LegendX swaps.
    /// @param limit The allowed deviation in basis points (e.g., 500 = 5%).
    function setTitanXDeviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        if (limit > BPS_BASE) revert Prohibited();
        titanXDeviation = limit;
    }

    /// @notice Sets the allowed price deviation for TWAP checks during X28 -> TitanX swaps.
    /// @param limit The allowed deviation in basis points (e.g., 500 = 5%).
    function setX28Deviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        if (limit > BPS_BASE) revert Prohibited();
        x28Deviation = limit;
    }

    /// @notice Sets the allowed price deviation for TWAP checks during ETH -> TitanX swaps.
    /// @param limit The allowed deviation in basis points (e.g., 500 = 5%).
    function setEthDeviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert ZeroInput();
        if (limit > BPS_BASE) revert Prohibited();
        ethDeviation = limit;
    }

    // ---------------------------- VIEW FUNCTIONS ------------------------- //

    /// @notice Returns parameters for the next Buy & Burn call.
    /// @return additionalSwap If the additional swap of X28 -> TitanX will be performed.
    /// @return titanXAmount TitanX amount used in the next swap
    /// @return x28Amount X28 amount used in the next swap (if additional swap is needed).
    /// @return nextAvailable Timestamp in seconds when next Buy & Burn will be available.
    function getBuyBurnParams()
        external
        view
        returns (bool additionalSwap, uint256 titanXAmount, uint256 x28Amount, uint256 nextAvailable)
    {
        uint256 titanXBalance = IERC20(TITANX).balanceOf(address(this));
        uint256 x28Balance = IERC20(X28).balanceOf(address(this));
        additionalSwap = titanXBalance < capPerSwapTitanX && x28Balance > 0;
        titanXAmount = titanXBalance > capPerSwapTitanX ? capPerSwapTitanX : titanXBalance;
        x28Amount = x28Balance > capPerSwapX28 ? capPerSwapX28 : x28Balance;
        nextAvailable = lastBuyBurn + buyBurnInterval;
    }

    /// @notice Returns parameters for the next ETH -> TitanX swap.
    /// @return ethAmount ETH amount used in the next swap.
    /// @return nextAvailable Timestamp in seconds when next swap will be available.
    function getEthSwapParams() external view returns (uint256 ethAmount, uint256 nextAvailable) {
        uint256 ethBalance = address(this).balance;
        ethAmount = ethBalance > capPerSwapEth ? capPerSwapEth : ethBalance;
        nextAvailable = lastEthSwap + buyBurnInterval;
    }

    /// @notice Returns current balances of the Buy & Burn contract.
    function getBalances() external view returns (uint256 titanXBalance, uint256 x28Balance, uint256 ethBalance) {
        titanXBalance = IERC20(TITANX).balanceOf(address(this));
        x28Balance = IERC20(X28).balanceOf(address(this));
        ethBalance = address(this).balance;
    }

    // -------------------------- INTERNAL FUNCTIONS ----------------------- //

    function _handleX28BalanceCheck(uint256 currentTitanXBalance, uint256 minTitanXAmount, uint256 deadline)
        internal
        returns (uint256)
    {
        uint256 x28Balance = IERC20(X28).balanceOf(address(this));
        if (x28Balance == 0) return currentTitanXBalance;
        uint256 amountToSwap = x28Balance > capPerSwapX28 ? capPerSwapX28 : x28Balance;
        uint256 swappedAmount = _swapX28forTitanX(amountToSwap, minTitanXAmount, deadline);
        unchecked {
            return currentTitanXBalance + swappedAmount;
        }
    }

    function _processIncentiveFee(uint256 titanXAmount) internal returns (uint256) {
        uint256 incentiveFee = titanXAmount * incentiveFeeBps / BPS_BASE;
        IERC20(TITANX).safeTransfer(msg.sender, incentiveFee);
        unchecked {
            return titanXAmount - incentiveFee;
        }
    }

    function _swapTitanXtoLegendX(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        internal
        returns (uint256)
    {
        _twapCheck(TITANX, LGNDX, amountIn, minAmountOut, titanXDeviation, TITANX_LGNDX_POOL);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: TITANX,
            tokenOut: LGNDX,
            fee: POOL_FEE_1PERCENT,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });
        IERC20(TITANX).safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountIn);
        return ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(params);
    }

    function _swapX28forTitanX(uint256 amountIn, uint256 minAmountOut, uint256 deadline) internal returns (uint256) {
        _twapCheck(X28, TITANX, amountIn, minAmountOut, x28Deviation, TITANX_X28_POOL);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: X28,
            tokenOut: TITANX,
            fee: POOL_FEE_1PERCENT,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });
        IERC20(X28).safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountIn);
        return ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(params);
    }

    function _swapEthforTitanX(uint256 amountIn, uint256 minAmountOut, uint256 deadline) internal returns (uint256) {
        _twapCheck(WETH, TITANX, amountIn, minAmountOut, ethDeviation, TITANX_WETH_POOL);
        IWETH9(WETH).deposit{value: amountIn}();
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: TITANX,
            fee: POOL_FEE_1PERCENT,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });
        IERC20(WETH).safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountIn);
        return ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(params);
    }

    function _twapCheck(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint32 deviation,
        address poolAddress
    ) internal view {
        uint32 _secondsAgo = secondsAgo;
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(poolAddress);
        if (oldestObservation < _secondsAgo) {
            _secondsAgo = oldestObservation;
        }

        (int24 arithmeticMeanTick,) = OracleLibrary.consult(poolAddress, _secondsAgo);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        uint256 twapAmountOut =
            OracleLibrary.getQuoteForSqrtRatioX96(sqrtPriceX96, uint128(amountIn), tokenIn, tokenOut);
        uint256 lowerBound = (twapAmountOut * (BPS_BASE - deviation)) / BPS_BASE;
        if (minAmountOut < lowerBound) revert TWAP();
    }
}
