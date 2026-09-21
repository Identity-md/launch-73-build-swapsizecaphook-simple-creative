# Vendored dependencies

Plain-file copies (no submodules) so the project builds offline. Only `src/`, licenses and READMEs were kept, plus `lib/v4-core/test/utils/CurrencySettler.sol` (imported by v4-core's `PoolSwapTest`/`PoolModifyLiquidityTest`).

| Path | Upstream | Commit |
| --- | --- | --- |
| lib/v4-core | https://github.com/Uniswap/v4-core | 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 |
| lib/solmate | https://github.com/transmissions11/solmate | 4b47a19038b798b4a33d9749d25e570443520647 (the commit v4-core pins) |
| lib/forge-std | https://github.com/foundry-rs/forge-std | 77041d2ce690e692d6e03cc812b57d1ddaa4d505 (tag v1.9.7) |
