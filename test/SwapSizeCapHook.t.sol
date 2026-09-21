// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SwapSizeCapHook} from "../src/SwapSizeCapHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SwapSizeCapHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    int24 constant FULL_LOWER = -887220;
    int24 constant FULL_UPPER = 887220;
    uint256 constant CAP_BPS = 1_000; // one tenth
    uint128 constant LIQ = 100 ether;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    SwapSizeCapHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        address hookAddr = address(uint160(HookFlags.BEFORE_SWAP) | (uint160(0x4444) << 144));
        deployCodeTo("SwapSizeCapHook.sol:SwapSizeCapHook", abi.encode(manager, CAP_BPS), hookAddr);
        hook = SwapSizeCapHook(hookAddr);

        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        key = _key(3_000, 60);
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key, FULL_LOWER, FULL_UPPER, int256(uint256(LIQ)), 0);
    }

    // ---------------------------------------------------------------- helpers

    function _key(uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, spacing, IHooks(address(hook)));
    }

    function _addLiquidity(PoolKey memory k, int24 lower, int24 upper, int256 delta, bytes32 salt) internal {
        lpRouter.modifyLiquidity(k, ModifyLiquidityParams(lower, upper, delta, salt), "");
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k,
            SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_LIMIT : MAX_LIMIT),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _expectCapRevert(PoolId poolId, uint256 amount, uint256 cap) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SwapSizeCapHook.SwapTooLarge.selector, poolId, amount, cap),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _cap() internal pure returns (uint256) {
        return uint256(LIQ) * CAP_BPS / 10_000;
    }

    // ---------------------------------------------------------------- construction

    function test_constructorStoresImmutables() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.CAP_BPS(), CAP_BPS);
        assertEq(hook.maxSwapAmount(id), 10 ether);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.BEFORE_SWAP);
    }

    function test_constructorRejectsInvalidCap() public {
        address at = address(uint160(HookFlags.BEFORE_SWAP) | (uint160(0x5555) << 144));
        vm.expectRevert(SwapSizeCapHook.InvalidCap.selector);
        deployCodeTo("SwapSizeCapHook.sol:SwapSizeCapHook", abi.encode(manager, uint256(0)), at);
        vm.expectRevert(SwapSizeCapHook.InvalidCap.selector);
        deployCodeTo("SwapSizeCapHook.sol:SwapSizeCapHook", abi.encode(manager, uint256(10_001)), at);
    }

    function test_constructorRejectsAddressWithWrongFlags() public {
        address at = address(uint160(HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP) | (uint160(0x6666) << 144));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, at));
        deployCodeTo("SwapSizeCapHook.sol:SwapSizeCapHook", abi.encode(manager, CAP_BPS), at);
    }

    function test_create2MinedDeploymentWorks() public {
        bytes memory code = abi.encodePacked(type(SwapSizeCapHook).creationCode, abi.encode(manager, CAP_BPS));
        bytes32 h = keccak256(code);
        for (uint256 i; i < 100_000; i++) {
            address predicted = vm.computeCreate2Address(bytes32(i), h, address(this));
            if (!HookFlags.matches(predicted, HookFlags.BEFORE_SWAP)) continue;
            SwapSizeCapHook h2 = new SwapSizeCapHook{salt: bytes32(i)}(manager, CAP_BPS);
            assertEq(address(h2), predicted);
            return;
        }
        fail();
    }

    // ---------------------------------------------------------------- exact input

    function test_exactInput_zeroForOne_atCapSucceeds() public {
        uint256 bal0 = token0.balanceOf(address(this));
        BalanceDelta d = _swap(key, true, -int256(_cap()));
        assertEq(d.amount0(), -int128(int256(_cap())));
        assertGt(d.amount1(), 0);
        assertEq(bal0 - token0.balanceOf(address(this)), _cap());
    }

    function test_exactInput_zeroForOne_aboveCapReverts() public {
        _expectCapRevert(id, _cap() + 1, _cap());
        _swap(key, true, -int256(_cap() + 1));
    }

    function test_exactInput_oneForZero_atCapSucceeds() public {
        BalanceDelta d = _swap(key, false, -int256(_cap()));
        assertEq(d.amount1(), -int128(int256(_cap())));
        assertGt(d.amount0(), 0);
    }

    function test_exactInput_oneForZero_aboveCapReverts() public {
        _expectCapRevert(id, _cap() + 1, _cap());
        _swap(key, false, -int256(_cap() + 1));
    }

    // ---------------------------------------------------------------- exact output

    function test_exactOutput_zeroForOne_atCapSucceeds() public {
        BalanceDelta d = _swap(key, true, int256(_cap()));
        assertEq(d.amount1(), int128(int256(_cap())));
        assertLt(d.amount0(), 0);
    }

    function test_exactOutput_zeroForOne_aboveCapReverts() public {
        _expectCapRevert(id, _cap() + 1, _cap());
        _swap(key, true, int256(_cap() + 1));
    }

    function test_exactOutput_oneForZero_atCapSucceeds() public {
        BalanceDelta d = _swap(key, false, int256(_cap()));
        assertEq(d.amount0(), int128(int256(_cap())));
        assertLt(d.amount1(), 0);
    }

    function test_exactOutput_oneForZero_aboveCapReverts() public {
        _expectCapRevert(id, _cap() + 1, _cap());
        _swap(key, false, int256(_cap() + 1));
    }

    function test_revertedSwapLeavesPoolUntouched() public {
        (uint160 before,,,) = manager.getSlot0(id);
        _expectCapRevert(id, 50 ether, _cap());
        _swap(key, true, -50 ether);
        (uint160 afterPrice,,,) = manager.getSlot0(id);
        assertEq(afterPrice, before);
    }

    function test_manySmallSwapsEachUnderCapSucceed() public {
        for (uint256 i; i < 5; i++) {
            _swap(key, i % 2 == 0, -int256(_cap()));
        }
    }

    // ---------------------------------------------------------------- cap follows liquidity

    function test_capGrowsWithAddedLiquidity() public {
        _expectCapRevert(id, 15 ether, 10 ether);
        _swap(key, true, -15 ether);

        _addLiquidity(key, FULL_LOWER, FULL_UPPER, int256(uint256(LIQ)), bytes32(uint256(1)));
        assertEq(hook.maxSwapAmount(id), 20 ether);
        _swap(key, true, -15 ether);
    }

    function test_capShrinksWhenLiquidityLeaves_andLPsCanAlwaysExit() public {
        _addLiquidity(key, FULL_LOWER, FULL_UPPER, -int256(uint256(LIQ / 2)), 0);
        assertEq(hook.maxSwapAmount(id), 5 ether);
        _expectCapRevert(id, 6 ether, 5 ether);
        _swap(key, true, -6 ether);

        // Full exit is never blocked by the hook.
        _addLiquidity(key, FULL_LOWER, FULL_UPPER, -int256(uint256(LIQ / 2)), 0);
        assertEq(manager.getLiquidity(id), 0);
        assertEq(hook.maxSwapAmount(id), 0);

        // With no liquidity every swap is over the cap.
        _expectCapRevert(id, 1, 0);
        _swap(key, true, -1);
    }

    function test_onlyInRangeLiquidityCounts() public {
        PoolKey memory k = _key(500, 10);
        manager.initialize(k, SQRT_PRICE_1_1);
        // Position entirely above the current tick: not active liquidity.
        _addLiquidity(k, 600, 1200, 100 ether, 0);
        assertEq(hook.maxSwapAmount(k.toId()), 0);
        _expectCapRevert(k.toId(), 1 ether, 0);
        _swap(k, false, -1 ether);
    }

    // ---------------------------------------------------------------- isolation & auth

    function test_capsArePerPool() public {
        PoolKey memory k2 = _key(500, 10);
        PoolId id2 = k2.toId();
        manager.initialize(k2, SQRT_PRICE_1_1);
        _addLiquidity(k2, -887270, 887270, 1_000 ether, 0);

        assertEq(hook.maxSwapAmount(id), 10 ether);
        assertEq(hook.maxSwapAmount(id2), 100 ether);

        _swap(k2, true, -50 ether);
        _expectCapRevert(id, 50 ether, 10 ether);
        _swap(key, true, -50 ether);
    }

    function test_directCallbacksFromNonManagerRevert() public {
        SwapParams memory p = SwapParams(true, -1, MIN_LIMIT);
        vm.expectRevert(SwapSizeCapHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");

        ModifyLiquidityParams memory m = ModifyLiquidityParams(-60, 60, 1 ether, 0);
        vm.expectRevert(SwapSizeCapHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(SwapSizeCapHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(SwapSizeCapHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, m, "");
        vm.expectRevert(SwapSizeCapHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, m, "");
        vm.expectRevert(SwapSizeCapHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
    }

    function test_undeclaredCallbacksRefuseEvenFromManager() public {
        vm.prank(address(manager));
        vm.expectRevert(SwapSizeCapHook.HookNotImplemented.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, MIN_LIMIT), BalanceDelta.wrap(0), "");
    }

    function test_hookDataAndSenderGrantNoExemption() public {
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(SwapSizeCapHook.SwapTooLarge.selector, id, 11 ether, 10 ether));
        hook.beforeSwap(address(manager), key, SwapParams(true, -11 ether, MIN_LIMIT), abi.encode(address(this)));
    }

    function test_int256MinDoesNotOverflow() public {
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(SwapSizeCapHook.SwapTooLarge.selector, id, uint256(1) << 255, 10 ether));
        hook.beforeSwap(address(this), key, SwapParams(true, type(int256).min, MIN_LIMIT), "");
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_capBoundary(uint256 amount, bool zeroForOne, bool exactInput) public {
        amount = bound(amount, 1, 40 ether);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        if (amount > _cap()) {
            _expectCapRevert(id, amount, _cap());
        }
        _swap(key, zeroForOne, specified);
    }
}
