# SwapSizeCapHook

A minimal Uniswap v4 hook that caps any single swap at a fixed fraction of the pool's current
liquidity. In `beforeSwap`, the hook reads the pool's active liquidity `L` from the PoolManager
(`StateLibrary.getLiquidity`) and reverts with `SwapTooLarge(poolId, amount, cap)` when

```
|amountSpecified| > L * CAP_BPS / 10_000
```

`CAP_BPS = 1_000` gives the one-tenth cap this project was designed around. The check is the same
for exact-input (negative `amountSpecified`) and exact-output (positive) swaps, in both directions.

This repository is source and tests only. It has no token, no deployment script and no launch
manifest.

## Layout

| Path | Contents |
| --- | --- |
| `src/SwapSizeCapHook.sol` | The hook |
| `src/HookFlags.sol` | Permission-bit constants and helpers for mining and checking hook addresses |
| `test/SwapSizeCapHook.t.sol` | Tests against a real v4-core `PoolManager`, using `PoolSwapTest` and `PoolModifyLiquidityTest` |
| `test/mocks/MockERC20.sol` | Test-only ERC-20 |
| `lib/` | Vendored dependencies as plain files, pinned in [`lib/VENDORED.md`](lib/VENDORED.md) |

## Build and test (offline)

```sh
forge build
forge test
forge fmt --check
```

Requirements: Foundry and solc 0.8.26 in the local svm cache. `offline = true` is set in
`foundry.toml`, so forge cannot download a compiler. `ffi` is off and there are no `fs_permissions`.

## Design

- **Permissions:** only `beforeSwap`. The hook sets none of the `*ReturnDelta` flags, so it can
  never take or change swap amounts; it can only allow a swap or revert it. The constructor calls
  `Hooks.validateHookPermissions`, so deploying at an address with the wrong flag bits reverts.
- **Authentication:** every callback, including the ones that are not declared, reverts with
  `NotPoolManager` unless `msg.sender` is the immutable `poolManager`. Callbacks that are not
  declared also revert `HookNotImplemented` when the manager calls them. `sender` and `hookData`
  are ignored, so no caller or router gets an exemption.
- **Per-pool isolation:** the hook stores nothing. Each pool's cap is computed from that pool's own
  `PoolId` on every swap. One deployment can serve many pools, and they cannot affect each other.
- **LP exits:** the hook does not register any liquidity callbacks, so it cannot block adding or
  removing liquidity. When liquidity is withdrawn, the cap shrinks with it. At zero active
  liquidity, every non-zero swap reverts.
- **No admin:** there is no owner, setter, pause, upgrade, `DELEGATECALL` or `SELFDESTRUCT`. The
  fraction is a constructor immutable.
- **Dynamic fee:** not used. The design does not need a dynamic fee, so the hook does not require
  `LPFeeLibrary.DYNAMIC_FEE_FLAG` and registers no `afterInitialize` validation. It works with any
  fee tier and tick spacing.

## Assumptions and limitations

1. **Units.** `L` is liquidity (units of sqrt(x·y)), not a token amount. The cap compares a raw
   token amount against `L / 10`. At price 1 with full-range liquidity and equal decimals, `L` is
   about the size of each reserve, so the cap is about 10% of reserves. Away from price 1, with
   concentrated liquidity or with mismatched token decimals, the cap in terms of either token can
   be much tighter or much looser. Choose `CAP_BPS` for your specific pool.
2. **Active liquidity only.** `getLiquidity` returns only in-range liquidity. Out-of-range
   positions do not count, and the cap moves as the price crosses ticks. A swap within the cap can
   still move the price a long way when liquidity past the current range is thin.
3. **Per swap, not per user or per block.** A trader can split a large trade into several capped
   swaps, in one transaction or across several. This hook limits the size of each single swap, not
   total flow. It is a guard against fat-finger trades and thin-pool manipulation, not MEV
   protection.
4. **Liquidity can be manipulated inside a transaction.** Anyone can add liquidity just in time to
   raise the cap, swap, and then remove it. This is allowed by design.
5. **Tests are not an audit.** The suite covers the cap boundary for both directions and both
   exact-input and exact-output swaps, a fuzzed boundary, cap tracking as liquidity is added and
   removed, full LP exit, per-pool isolation, caller authentication, and address/flag validation.
   Get an independent review before using this hook in production.

## Deployment parameters (for whoever deploys it)

| Parameter | Meaning |
| --- | --- |
| `_poolManager` | The canonical v4 `PoolManager` on the target chain. Check it against Uniswap's official deployment list. A wrong value makes every swap revert. |
| `capBps` | The fraction in basis points, between 1 and 10_000. Use `1_000` for one tenth. Fixed forever. |

Deploy with CREATE2 using a salt mined so that the low 14 bits of the address equal
`HookFlags.BEFORE_SWAP` (`0x0080`) and nothing else. `test_create2MinedDeploymentWorks` shows how.
Operationally, the only responsibility is choosing `capBps`. Because the hook has no admin keys, a
cap that turns out to be wrong can only be fixed by deploying a new hook and new pools.

## License

MIT. Vendored dependencies keep their own licenses under `lib/`.
