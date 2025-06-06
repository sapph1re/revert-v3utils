// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Automator.sol";

/// @title AutoExit
/// @notice Lets a v3 position to be automatically removed (limit order) or swapped to the opposite token (stop loss order) when it reaches a certain tick.
/// A revert controlled bot (operator) is responsable for the execution of optimized swaps (using external swap router)
/// Positions need to be approved (approve or setApprovalForAll) for the contract and configured with configToken method
contract AutoExit is Automator {
    event Executed(
        uint256 indexed tokenId,
        address account,
        bool isSwap,
        uint256 amountReturned0,
        uint256 amountReturned1,
        address token0,
        address token1,
        address swappedToToken
    );
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        address swapAlwaysToToken,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        bool onlyFees,
        uint64 maxRewardX64
    );

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _zeroxRouter,
        address _universalRouter
    ) Automator(_npm, _operator, _withdrawer, _TWAPSeconds, _maxTWAPTickDifference, _zeroxRouter, _universalRouter) {}

    // define how stoploss / limit should be handled
    struct PositionConfig {
        bool isActive; // if position is active
        // should swap token to other token when triggered
        bool token0Swap;
        bool token1Swap;
        // when should action be triggered (when this tick is reached - allow execute)
        int24 token0TriggerTick; // when tick is below this one
        int24 token1TriggerTick; // when tick is equal or above this one
        // swap always to this token, if it is not zero
        address swapAlwaysToToken;
        // max price difference from current pool price for swap / Q64
        uint64 token0SlippageX64; // when token 0 is swapped to token 1
        uint64 token1SlippageX64; // when token 1 is swapped to token 0
        bool onlyFees; // if only fees maybe used for protocol reward
        uint64 maxRewardX64; // max allowed reward percentage of fees or full position
    }

    // configured tokens
    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId; // tokenid to process
        bytes swapData; // if its a swap order - may include swap data for a complex route
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 deadline; // for uniswap operations
        uint64 rewardX64; // which reward will be used for protocol, can be max configured amount (considering onlyFees)
    }

    struct ExecuteState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        IUniswapV3Pool pool;
        uint256 swapAmount;
        int24 tick;
        bool isSwap;
        bool swap0For1;
        bool isAbove;
        address owner;
    }

    /**
     * @notice Handle token (must be in correct state)
     * Can only be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function execute(ExecuteParams calldata params) external {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }

        PositionConfig memory config = positionConfigs[params.tokenId];

        if (!config.isActive) {
            revert NotConfigured();
        }

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        ExecuteState memory state;

        // get position info
        (,, state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.liquidity,,,,) =
            nonfungiblePositionManager.positions(params.tokenId);

        // so can be executed only once
        if (state.liquidity == 0) {
            revert NoLiquidity();
        }

        state.pool = _getPool(state.token0, state.token1, state.fee);
        (, state.tick,,,,,) = state.pool.slot0();

        // not triggered
        if (config.token0TriggerTick <= state.tick && state.tick < config.token1TriggerTick) {
            revert NotReady();
        }

        state.isAbove = state.tick >= config.token1TriggerTick;
        if (config.swapAlwaysToToken != address(0)) {
            if (config.swapAlwaysToToken != state.token0 && config.swapAlwaysToToken != state.token1) {
                revert InvalidConfig();
            }
            state.isSwap = true;
            state.swap0For1 = config.swapAlwaysToToken == state.token1;
        } else {
            state.isSwap = !state.isAbove && config.token0Swap || state.isAbove && config.token1Swap;
            state.swap0For1 = state.isSwap && !state.isAbove;
        }

        // decrease full liquidity for given position - and return fees as well
        (state.amount0, state.amount1, state.feeAmount0, state.feeAmount1) = _decreaseFullLiquidityAndCollect(
            params.tokenId, state.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline
        );

        // swap to other token
        if (state.isSwap) {
            // reward is taken before swap - if from fees only
            if (config.onlyFees) {
                state.amount0 -= state.feeAmount0 * params.rewardX64 / Q64;
                state.amount1 -= state.feeAmount1 * params.rewardX64 / Q64;
            }

            state.swapAmount = state.swap0For1 ? state.amount0 : state.amount1;
            if (state.swapAmount != 0) {
                (state.sqrtPriceX96, state.currentTick,,,,,) = state.pool.slot0();

                // checks if price in valid oracle range and calculates amountOutMin
                state.amountOutMin = _validateSwap(
                    state.swap0For1,
                    state.swapAmount,
                    state.pool,
                    state.currentTick,
                    state.sqrtPriceX96,
                    TWAPSeconds,
                    maxTWAPTickDifference,
                    state.swap0For1 ? config.token0SlippageX64 : config.token1SlippageX64
                );

                if (params.swapData.length == 0) {
                    // simple swap through the same pool
                    (state.amountInDelta, state.amountOutDelta) = _poolSwap(
                        Swapper.PoolSwapParams(
                            IUniswapV3Pool(_getPool(state.token0, state.token1, state.fee)),
                            IERC20(state.token0),
                            IERC20(state.token1),
                            state.fee,
                            state.swap0For1,
                            state.swapAmount,
                            state.amountOutMin
                        )
                    );
                } else {
                    // swap through the provided route
                    (state.amountInDelta, state.amountOutDelta) = _routerSwap(
                        Swapper.RouterSwapParams(
                            state.swap0For1 ? IERC20(state.token0) : IERC20(state.token1),
                            state.swap0For1 ? IERC20(state.token1) : IERC20(state.token0),
                            state.swapAmount,
                            state.amountOutMin,
                            params.swapData
                        )
                    );
                }

                if (state.swap0For1) { // Swapping token0 for token1
                    // token0 is input (amountInDelta), token1 is output (amountOutDelta)
                    state.amount0 = state.amount0 - state.amountInDelta;
                    state.amount1 = state.amount1 + state.amountOutDelta;
                } else { // Swapping token1 for token0
                    // token1 is input (amountInDelta), token0 is output (amountOutDelta)
                    state.amount0 = state.amount0 + state.amountOutDelta;
                    state.amount1 = state.amount1 - state.amountInDelta;
                }
            }

            // when swap and !onlyFees - protocol reward is removed only from target token (to incentivize optimal swap done by operator)
            if (!config.onlyFees) {
                // Reward is taken from the token that was received from the swap
                if (state.swap0For1) { // Swapped to token1 (token1 was received)
                    state.amount1 -= state.amount1 * params.rewardX64 / Q64;
                } else { // Swapped to token0 (token0 was received)
                    state.amount0 -= state.amount0 * params.rewardX64 / Q64;
                }
            }
        } else {
            // reward is taken as configured
            state.amount0 -= (config.onlyFees ? state.feeAmount0 : state.amount0) * params.rewardX64 / Q64;
            state.amount1 -= (config.onlyFees ? state.feeAmount1 : state.amount1) * params.rewardX64 / Q64;
        }

        state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);
        if (state.amount0 != 0) {
            _transferToken(state.owner, IERC20(state.token0), state.amount0, true);
        }
        if (state.amount1 != 0) {
            _transferToken(state.owner, IERC20(state.token1), state.amount1, true);
        }

        // delete config for position
        delete positionConfigs[params.tokenId];
        emit PositionConfigured(params.tokenId, false, false, false, address(0), 0, 0, 0, 0, false, 0);

        // log event
        emit Executed(
            params.tokenId,
            msg.sender,
            state.isSwap,
            state.amount0,
            state.amount1,
            state.token0,
            state.token1,
            state.swap0For1 ? state.token1 : state.token0
        );
    }

    // function to configure a token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        if (config.isActive) {
            if (config.token0TriggerTick >= config.token1TriggerTick) {
                revert InvalidConfig();
            }
            address token0;
            address token1;
            (,, token0, token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
            if (config.swapAlwaysToToken != address(0)) {
                if (config.swapAlwaysToToken != token0 && config.swapAlwaysToToken != token1) {
                    revert InvalidConfig();
                }
            }
        }

        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.token0Swap,
            config.token1Swap,
            config.swapAlwaysToToken,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.token0SlippageX64,
            config.token1SlippageX64,
            config.onlyFees,
            config.maxRewardX64
        );
    }
}
