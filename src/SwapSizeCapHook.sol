// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SwapSizeCapHook
/// @notice Caps the size of a single swap at a fixed fraction of the pool's current in-range liquidity.
/// @dev `beforeSwap` reads `liquidity` for the pool from the canonical PoolManager and reverts when
/// `|amountSpecified| > liquidity * CAP_BPS / 10_000`. The check applies identically to exact-input
/// (negative `amountSpecified`) and exact-output (positive) swaps and to both directions.
///
/// The hook is stateless: it stores nothing per pool, so pools cannot interfere with each other, and
/// it never touches liquidity callbacks, so LPs can always add and remove. There is no owner, no
/// setter and no upgrade path; the fraction is an immutable set at construction.
///
/// Note on units: `liquidity` is the v4 `L` value (sqrt(x*y) units), not a token amount. Comparing it
/// with a token amount is exactly what this design specifies; see README for what that implies.
contract SwapSizeCapHook is IHooks {
    using StateLibrary for IPoolManager;

    /// @notice Denominator for `CAP_BPS`.
    uint256 public constant BPS = 10_000;

    /// @notice The canonical PoolManager. The only address allowed to invoke callbacks.
    IPoolManager public immutable poolManager;

    /// @notice Maximum swap size as a fraction of current liquidity, in basis points (1_000 = one tenth).
    uint256 public immutable CAP_BPS;

    error NotPoolManager();
    error HookNotImplemented();
    error InvalidCap();
    /// @notice Thrown by `beforeSwap` when the specified amount exceeds the cap.
    error SwapTooLarge(PoolId poolId, uint256 amount, uint256 cap);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The canonical v4 PoolManager on the target chain.
    /// @param capBps Cap as basis points of liquidity, in [1, 10_000]. 1_000 means one tenth.
    constructor(IPoolManager _poolManager, uint256 capBps) {
        if (capBps == 0 || capBps > BPS) revert InvalidCap();
        poolManager = _poolManager;
        CAP_BPS = capBps;
        // The deployment address must advertise exactly the permissions implemented below.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The current maximum `|amountSpecified|` accepted for a pool.
    function maxSwapAmount(PoolId poolId) public view returns (uint256) {
        return uint256(poolManager.getLiquidity(poolId)) * CAP_BPS / BPS;
    }

    /// @inheritdoc IHooks
    /// @dev `sender` and `hookData` are ignored: the cap applies to every caller alike.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        int256 specified = params.amountSpecified;
        // Absolute value without overflowing on type(int256).min.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = specified < 0 ? uint256(-(specified + 1)) + 1 : uint256(specified);
        uint256 cap = maxSwapAmount(id);
        if (amount > cap) revert SwapTooLarge(id, amount, cap);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not declare. The PoolManager never calls them (the address bits are
    // unset); they still authenticate the caller first and then refuse.
    // ---------------------------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
